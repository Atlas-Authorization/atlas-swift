import XCTest
@testable import Atlas

final class BillingTests: XCTestCase {
    override func setUp() { super.setUp(); MockURLProtocol.reset() }

    private func client() -> AtlasClient {
        AtlasClient(
            publishableKey: "pk_test_123", frontendApi: "clerk.example.com",
            tokenStore: InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt")),
            urlSession: MockURLProtocol.makeSession()
        )
    }

    private func body(_ i: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[i]) as? [String: Any])
    }

    private let plan = #"{"object":"billing_plan","id":"plan_pro","name":"Pro","slug":"pro","interval":"month","amount":1000,"currency":"usd","features":["SSO"],"audience":"user","annual_available":true,"annual_amount":"9600","trial_days":14,"promotion":{"label":"Launch","percent_off":50,"code":"LAUNCH"}}"#

    func testPlansDecodeAndSort() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"list","data":[{"id":"b","name":"B","sort_order":2,"amount":0},"# + plan.replacingOccurrences(of: "\"id\":\"plan_pro\"", with: "\"id\":\"a\",\"sort_order\":1") + "]}")
        let plans = try await client().billingPlans()
        XCTAssertEqual(plans.map(\.id), ["a", "b"])
        XCTAssertEqual(plans[0].annualAmount, 9600)
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/billing/plans")
    }

    func testPriceViewAppliesPromotionAndAnnual() throws {
        let p = try JSONDecoder().decode(BillingPlan.self, from: Data(plan.utf8))
        let monthly = p.priceView(interval: "month", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(monthly.amount, 500)
        XCTAssertEqual(monthly.originalPrice, "$10.00")
        XCTAssertEqual(monthly.trialDays, 14)
        XCTAssertEqual(monthly.promotionCode, "LAUNCH")
        let yearly = p.priceView(interval: "year", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(yearly.interval, "year")
        XCTAssertEqual(yearly.amount, 4800)
    }

    func testExpiredPromotionIgnored() throws {
        let json = plan.replacingOccurrences(of: "\"code\":\"LAUNCH\"", with: "\"code\":\"LAUNCH\",\"ends_at\":1000")
        let p = try JSONDecoder().decode(BillingPlan.self, from: Data(json.utf8))
        XCTAssertEqual(p.priceView(now: Date()).amount, 1000)
    }

    func testSubscriptionReadsOrgQueryAndAddons() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"billing_subscription","subject_type":"org","status":"active","id":"sub_1","cancel_at_period_end":true,"subscriptions":[{"id":"sub_1","status":"active","subject_type":"org"},{"id":"sub_2","status":"trialing","subject_type":"org","plan":{"id":"x","kind":"addon"}}]}"#)
        let sub = try await client().billingSubscription(orgId: "org_1")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.absoluteString, "https://clerk.example.com/v1/client/billing/subscription?org_id=org_1")
        XCTAssertTrue(sub.isLive)
        XCTAssertTrue(sub.cancelAtPeriodEnd)
        XCTAssertEqual(sub.liveAddons.map(\.id), ["sub_2"])
    }

    func testNeverSubscribedHasNilStatus() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"billing_subscription","subject_type":"user","status":null,"plan":null}"#)
        let sub = try await client().billingSubscription()
        XCTAssertNil(sub.status)
        XCTAssertTrue(sub.all.isEmpty)
    }

    func testCheckoutBody() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"url":"https://checkout.example/s/1"}"#)
        let url = try await client().billingCheckout(
            planId: "plan_pro", orgId: "org_1",
            successURL: URL(string: "app://ok")!, cancelURL: URL(string: "app://no")!,
            interval: "year", couponCode: "LAUNCH"
        )
        XCTAssertEqual(url.absoluteString, "https://checkout.example/s/1")
        XCTAssertEqual(MockURLProtocol.recorded[0].httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/billing/checkout")
        let b = try body(0)
        XCTAssertEqual(b["plan_id"] as? String, "plan_pro")
        XCTAssertEqual(b["org_id"] as? String, "org_1")
        XCTAssertEqual(b["success_url"] as? String, "app://ok")
        XCTAssertEqual(b["interval"] as? String, "year")
        XCTAssertEqual(b["coupon_code"] as? String, "LAUNCH")
    }

    func testPortalCancelRestoreChangePaths() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"url":"https://portal.example/p"}"#)
        _ = try await client().billingPortal(returnURL: URL(string: "app://back")!, subscriptionId: "sub 2")
        XCTAssertEqual(try body(0)["subscription_id"] as? String, "sub 2")
        let sub = #"{"object":"billing_subscription","subject_type":"user","status":"active"}"#
        MockURLProtocol.enqueue(status: 200, json: sub)
        _ = try await client().billingCancel(immediately: true)
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/billing/subscription/cancel")
        XCTAssertEqual(try body(1)["immediately"] as? Bool, true)
        MockURLProtocol.enqueue(status: 200, json: sub)
        _ = try await client().billingRestore(subscriptionId: "sub_2")
        XCTAssertEqual(MockURLProtocol.recorded[2].url?.path, "/v1/client/billing/subscriptions/sub_2/restore")
        MockURLProtocol.enqueue(status: 200, json: sub)
        _ = try await client().billingChangePlan(planId: "plan_b", atPeriodEnd: true)
        XCTAssertEqual(MockURLProtocol.recorded[3].url?.path, "/v1/client/billing/subscription/change")
        XCTAssertEqual(try body(3)["schedule_at_period_end"] as? Bool, true)
    }

    func testInvoicesPaymentMethodAndCheck() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"data":[{"id":"in_1","number":"A-1","status":"paid","amount_due":1000,"amount_paid":1000,"currency":"usd","hosted_invoice_url":"https://i/1","created_at":1700000000000}]}"#)
        let invoices = try await client().billingInvoices()
        XCTAssertEqual(invoices.first?.number, "A-1")
        MockURLProtocol.enqueue(status: 200, json: #"{"payment_method":{"brand":"visa","last4":"4242","exp_month":4,"exp_year":2030}}"#)
        let card = try await client().billingPaymentMethod()
        XCTAssertEqual(card?.last4, "4242")
        MockURLProtocol.enqueue(status: 200, json: #"{"payment_method":null}"#)
        let none = try await client().billingPaymentMethod()
        XCTAssertNil(none)
        MockURLProtocol.enqueue(status: 200, json: #"{"feature":"seats","allowed":true,"remaining":3,"unlimited":false}"#)
        let check = try await client().billingCheck(feature: "seats", required: 2)
        XCTAssertTrue(check.allowed)
        XCTAssertEqual(MockURLProtocol.recorded[3].url?.query, "feature=seats&required=2")
    }

    func testCouponValidation() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"valid":true,"discount":{"percent_off":20,"duration":"repeating","duration_months":3}}"#)
        let ok = try await client().billingValidateCoupon(planId: "plan_pro", code: " LAUNCH ")
        XCTAssertTrue(ok.valid)
        XCTAssertEqual(ok.percentOff, 20)
        XCTAssertEqual(ok.durationMonths, 3)
        XCTAssertEqual(try body(0)["code"] as? String, "LAUNCH")
        MockURLProtocol.enqueue(status: 200, json: #"{"valid":false,"reason":"invalid"}"#)
        let bad = try await client().billingValidateCoupon(planId: "plan_pro", code: "x")
        XCTAssertFalse(bad.valid)
        XCTAssertEqual(bad.reason, "invalid")
    }
}
