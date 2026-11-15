#if canImport(SwiftUI)
import XCTest
@testable import Atlas

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class ManagementUITests: XCTestCase {
    override func setUp() { super.setUp(); MockURLProtocol.reset() }

    private func client() -> AtlasClient {
        AtlasClient(
            publishableKey: "pk_test_123", frontendApi: "clerk.example.com",
            tokenStore: InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt")),
            urlSession: MockURLProtocol.makeSession()
        )
    }

    func testSlug() {
        XCTAssertEqual(OrganizationSwitcherModel.slug("Acme Corp!"), "acme-corp")
        XCTAssertEqual(OrganizationSwitcherModel.slug("  a  b "), "a-b")
    }

    func testSwitcherLoadsAndSwitches() async {
        MockURLProtocol.enqueue(status: 200, json: #"{"data":[{"role":"admin","organization":{"id":"org_1","name":"Acme"}}]}"#)
        let model = OrganizationSwitcherModel(client: client())
        await model.load()
        XCTAssertEqual(model.memberships.count, 1)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_1","jwt":"j2","last_active_organization_id":"org_1"}"#)
        await model.select("org_1")
        XCTAssertEqual(model.activeOrganizationId, "org_1")
    }

    func testCreateOrganizationSwitchesToIt() async {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"org_2","name":"Beta","slug":"beta"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_1","jwt":"j2","last_active_organization_id":"org_2"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"data":[{"role":"admin","organization":{"id":"org_2","name":"Beta"}}]}"#)
        let model = OrganizationSwitcherModel(client: client())
        let ok = await model.create(name: "Beta")
        XCTAssertTrue(ok)
        XCTAssertEqual(model.activeOrganizationId, "org_2")
        let created = try? JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[0]) as? [String: Any]
        XCTAssertEqual(created?["slug"] as? String, "beta")
    }

    func testApiKeysModelParksCreateOnStepUp() async {
        MockURLProtocol.enqueue(status: 403, json: #"{"errors":[{"code":"STEP_UP_REQUIRED","message":"x"}]}"#)
        let model = ApiKeysModel(client: client())
        await model.create(name: "CI", expiresInDays: 30, scopes: nil)
        XCTAssertTrue(model.needsStepUp)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_1","jwt":"fresh"}"#)
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"ak_1","prefix":"ak_x","secret":"ak_secret"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"data":[]}"#)
        await model.completeStepUp(password: "pw")
        XCTAssertEqual(model.createdSecret, "ak_secret")
        XCTAssertFalse(model.needsStepUp)
        let retry = try? JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[2]) as? [String: Any]
        XCTAssertEqual(retry?["expires_in_seconds"] as? Int, 30 * 86_400)
    }

    func testApiKeysDisabledOn403() async {
        MockURLProtocol.enqueue(status: 403, json: #"{"errors":[{"code":"FORBIDDEN","message":"off"}]}"#)
        let model = ApiKeysModel(client: client())
        await model.load()
        XCTAssertEqual(model.status, .disabled)
    }

    func testDeviceApprovalFlow() async {
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"da_1","user_code":"ABCD-EFGH","status":"pending","client":{"name":"Living room TV"},"scopes":[]}"#)
        let model = DeviceApprovalModel(client: client())
        await model.lookup("abcdefgh")
        guard case .pending = model.phase else { return XCTFail("expected pending") }
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"da_1","user_code":"ABCD-EFGH","status":"approved","client":{"name":"Living room TV"},"scopes":[]}"#)
        await model.decide(approve: true)
        XCTAssertEqual(model.phase, .approved)
    }

    func testDeviceApprovalStepUp() async {
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"da_1","user_code":"ABCD-EFGH","status":"pending","client":{"name":"TV"},"scopes":[],"requires_step_up":true}"#)
        let model = DeviceApprovalModel(client: client())
        await model.lookup("ABCD-EFGH")
        MockURLProtocol.enqueue(status: 403, json: #"{"errors":[{"code":"STEP_UP_REQUIRED","message":"x"}]}"#)
        await model.decide(approve: true)
        XCTAssertTrue(model.needsStepUp)
    }

    func testBillingSubscribeSwitchesInPlaceWhenLive() async {
        MockURLProtocol.enqueue(status: 200, json: #"{"data":[{"id":"a","name":"A","amount":0},{"id":"b","name":"B","amount":500}]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"subject_type":"user","status":"active","plan":{"id":"a","name":"A","amount":0}}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"data":[]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"payment_method":null}"#)
        let model = BillingModel(client: client(), returnURL: URL(string: "app://back")!)
        await model.load()
        MockURLProtocol.enqueue(status: 200, json: #"{"subject_type":"user","status":"active","plan":{"id":"b","name":"B","amount":500}}"#)
        let url = await model.subscribe(model.plans[1], interval: nil)
        XCTAssertNil(url)
        XCTAssertEqual(model.subscription?.plan?.id, "b")
        XCTAssertEqual(MockURLProtocol.recorded.last?.url?.path, "/v1/client/billing/subscription/change")
    }
}
#endif
