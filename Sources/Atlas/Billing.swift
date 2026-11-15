import Foundation

/// Billing over the Frontend API (`/v1/client/billing/*`): the instance's plans,
/// the signed-in subject's subscription, invoices and card, and the hosted
/// Checkout / Billing Portal URLs the provider issues. There is deliberately no
/// in-app card form: card entry stays on the provider's hosted page, the same
/// posture as the web components. Pass `orgId` to act on an organization the
/// user administers instead of on the user.

private func flexDouble<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
    if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
    if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
    return nil
}

/// A display-only promotion on a plan.
public struct BillingPromotion: Decodable, Sendable, Equatable {
    public let label: String
    public let percentOff: Double?
    public let amountOff: Double?
    public let endsAt: Double?
    public let code: String?

    enum CodingKeys: String, CodingKey {
        case label, code
        case percentOff = "percent_off"
        case amountOff = "amount_off"
        case endsAt = "ends_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code)
        percentOff = flexDouble(c, .percentOff)
        amountOff = flexDouble(c, .amountOff)
        endsAt = flexDouble(c, .endsAt)
    }
}

/// How a plan is priced for display (see ``BillingPlan/priceView(interval:locale:now:)``).
public struct BillingPriceView: Sendable, Equatable {
    public let price: String
    public let originalPrice: String?
    /// `month` or `year`.
    public let interval: String
    public let free: Bool
    public let trialDays: Int?
    public let promotionLabel: String?
    public let promotionCode: String?
    /// The amount in minor units after any promotion.
    public let amount: Double
}

/// A plan the instance sells (`GET /v1/client/billing/plans`).
public struct BillingPlan: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let slug: String
    /// `month` or `year`.
    public let interval: String
    /// Minor units (cents).
    public let amount: Double
    public let currency: String
    public let features: [String]
    /// `user` or `org`.
    public let audience: String
    public let provider: String?
    /// `base` (the subject's main plan) or `addon`.
    public let kind: String?
    public let trialDays: Int?
    public let annualAvailable: Bool
    public let annualAmount: Double?
    public let promotion: BillingPromotion?
    public let description: String?
    public let badge: String?
    public let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, interval, amount, currency, features, audience, provider, kind
        case promotion, description, badge
        case trialDays = "trial_days"
        case annualAvailable = "annual_available"
        case annualAmount = "annual_amount"
        case sortOrder = "sort_order"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        interval = try c.decodeIfPresent(String.self, forKey: .interval) ?? "month"
        amount = flexDouble(c, .amount) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "usd"
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        audience = try c.decodeIfPresent(String.self, forKey: .audience) ?? "user"
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        trialDays = (try? c.decodeIfPresent(Int.self, forKey: .trialDays)) ?? nil
        annualAvailable = try c.decodeIfPresent(Bool.self, forKey: .annualAvailable) ?? false
        annualAmount = flexDouble(c, .annualAmount)
        promotion = try? c.decodeIfPresent(BillingPromotion.self, forKey: .promotion)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        sortOrder = (try? c.decodeIfPresent(Int.self, forKey: .sortOrder)) ?? nil
    }

    /// A minor-unit amount as a locale-formatted currency string (`12.34 USD` when
    /// the currency code is not a known ISO code).
    public static func formatMoney(_ minor: Double, currency: String, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = currency.uppercased()
        return f.string(from: NSNumber(value: minor / 100)) ?? String(format: "%.2f %@", minor / 100, currency.uppercased())
    }

    /// The price, trial and promotion to show at `interval` (default the plan's
    /// own). A yearly interval uses `annualAmount` when the plan offers one; an
    /// expired promotion is ignored. Mirrors the web `planPriceView`.
    public func priceView(interval wanted: String? = nil, locale: Locale = .current, now: Date = Date()) -> BillingPriceView {
        let own = interval == "year" ? "year" : "month"
        let chosen = wanted ?? own
        let annual: Double? = (annualAvailable ? annualAmount : nil)
        let base: Double
        if chosen == own { base = amount } else if chosen == "year", let annual { base = annual } else { base = amount }
        let shown = (chosen == own || (chosen == "year" && annual != nil)) ? chosen : own
        var promo: BillingPromotion? = promotion
        if let p = promo, let ends = p.endsAt, ends <= now.timeIntervalSince1970 * 1000 { promo = nil }
        var final = base
        if let p = promo, let pct = p.percentOff, pct != 0 { final = (base * (1 - pct / 100)).rounded() }
        else if let p = promo, let off = p.amountOff, off != 0 { final = max(0, base - off) }
        let discounted = promo != nil && final < base
        return BillingPriceView(
            price: BillingPlan.formatMoney(final, currency: currency, locale: locale),
            originalPrice: discounted ? BillingPlan.formatMoney(base, currency: currency, locale: locale) : nil,
            interval: shown,
            free: final == 0 && base == 0,
            trialDays: (trialDays ?? 0) > 0 ? trialDays : nil,
            promotionLabel: promo?.label,
            promotionCode: promo?.code,
            amount: final
        )
    }
}

/// A subject's subscription (`GET /v1/client/billing/subscription`). `status` is
/// nil when the subject has never subscribed.
public struct BillingSubscription: Decodable, Sendable, Equatable {
    public let id: String?
    public let subjectType: String
    public let status: String?
    public let plan: BillingPlan?
    public let currentPeriodEnd: Double?
    public let cancelAtPeriodEnd: Bool
    public let interval: String?
    public let scheduledPlanId: String?
    public let trialEnd: Double?
    public let trialEligible: Bool
    /// Every subscription the subject holds (base plan and add-ons); empty on a
    /// server that predates several subscriptions.
    public let subscriptions: [BillingSubscription]

    enum CodingKeys: String, CodingKey {
        case id, status, plan, interval, subscriptions
        case subjectType = "subject_type"
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case scheduledPlanId = "scheduled_plan_id"
        case trialEnd = "trial_end"
        case trialEligible = "trial_eligible"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        subjectType = try c.decodeIfPresent(String.self, forKey: .subjectType) ?? "user"
        status = try c.decodeIfPresent(String.self, forKey: .status)
        plan = try? c.decodeIfPresent(BillingPlan.self, forKey: .plan)
        currentPeriodEnd = flexDouble(c, .currentPeriodEnd)
        cancelAtPeriodEnd = try c.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false
        interval = try c.decodeIfPresent(String.self, forKey: .interval)
        scheduledPlanId = try c.decodeIfPresent(String.self, forKey: .scheduledPlanId)
        trialEnd = flexDouble(c, .trialEnd)
        trialEligible = try c.decodeIfPresent(Bool.self, forKey: .trialEligible) ?? false
        subscriptions = (try? c.decodeIfPresent([BillingSubscription].self, forKey: .subscriptions)) ?? []
    }

    /// Statuses in which a subscription is still running.
    public static let liveStatuses = ["active", "trialing", "past_due"]

    public var isLive: Bool { status.map { BillingSubscription.liveStatuses.contains($0) } ?? false }

    /// Every subscription of the read: `subscriptions`, or the one it reports.
    public var all: [BillingSubscription] {
        if !subscriptions.isEmpty { return subscriptions }
        return status != nil ? [self] : []
    }

    /// The live add-on subscriptions.
    public var liveAddons: [BillingSubscription] {
        all.filter { $0.plan?.kind == "addon" && $0.isLive }
    }
}

/// A stored invoice (billing history).
public struct BillingInvoice: Decodable, Sendable, Equatable {
    public let id: String
    public let number: String?
    public let status: String
    public let amountDue: Double
    public let amountPaid: Double
    public let currency: String
    public let hostedInvoiceURL: String?
    public let invoicePDF: String?
    public let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, number, status, currency
        case amountDue = "amount_due"
        case amountPaid = "amount_paid"
        case hostedInvoiceURL = "hosted_invoice_url"
        case invoicePDF = "invoice_pdf"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = try c.decodeIfPresent(String.self, forKey: .number)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "usd"
        amountDue = flexDouble(c, .amountDue) ?? 0
        amountPaid = flexDouble(c, .amountPaid) ?? 0
        hostedInvoiceURL = try c.decodeIfPresent(String.self, forKey: .hostedInvoiceURL)
        invoicePDF = try c.decodeIfPresent(String.self, forKey: .invoicePDF)
        createdAt = flexDouble(c, .createdAt) ?? 0
    }
}

/// The subject's default card.
public struct BillingPaymentMethod: Decodable, Sendable, Equatable {
    public let brand: String
    public let last4: String
    public let expMonth: Int
    public let expYear: Int

    enum CodingKeys: String, CodingKey {
        case brand, last4
        case expMonth = "exp_month"
        case expYear = "exp_year"
    }
}

/// A live feature check (`GET /v1/client/billing/check`). For UI only: enforce on
/// your server or from the token.
public struct BillingFeatureCheck: Decodable, Sendable, Equatable {
    public let feature: String
    public let allowed: Bool
    public let source: String?
    public let remaining: Double?
    public let granted: Double?
    public let usage: Double?
    public let unlimited: Bool

    enum CodingKeys: String, CodingKey { case feature, allowed, source, remaining, granted, usage, unlimited }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feature = try c.decodeIfPresent(String.self, forKey: .feature) ?? ""
        allowed = try c.decodeIfPresent(Bool.self, forKey: .allowed) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source)
        remaining = flexDouble(c, .remaining)
        granted = flexDouble(c, .granted)
        usage = flexDouble(c, .usage)
        unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
    }
}

/// The result of checking a discount code (`POST /v1/client/billing/coupons/validate`).
public struct BillingCouponCheck: Decodable, Sendable, Equatable {
    public let valid: Bool
    /// Why it is not valid (`invalid`, …).
    public let reason: String?
    public let percentOff: Double?
    public let amountOff: Double?
    public let currency: String?
    public let duration: String?
    public let durationMonths: Int?

    enum CodingKeys: String, CodingKey { case valid, reason, discount }
    enum DiscountKeys: String, CodingKey {
        case percentOff = "percent_off", amountOff = "amount_off", currency, duration
        case durationMonths = "duration_months"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        valid = try c.decodeIfPresent(Bool.self, forKey: .valid) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        if let d = try? c.nestedContainer(keyedBy: DiscountKeys.self, forKey: .discount) {
            percentOff = flexDouble(d, .percentOff)
            amountOff = flexDouble(d, .amountOff)
            currency = try d.decodeIfPresent(String.self, forKey: .currency)
            duration = try d.decodeIfPresent(String.self, forKey: .duration)
            durationMonths = (try? d.decodeIfPresent(Int.self, forKey: .durationMonths)) ?? nil
        } else {
            percentOff = nil; amountOff = nil; currency = nil; duration = nil; durationMonths = nil
        }
    }
}

private struct BillingURLResponse: Decodable { let url: String }
private struct BillingPaymentMethodResponse: Decodable {
    let paymentMethod: BillingPaymentMethod?
    enum CodingKeys: String, CodingKey { case paymentMethod = "payment_method" }
}

extension AtlasClient {
    private func billingPath(_ path: String, _ query: [(String, String?)]) -> String {
        var components = URLComponents()
        components.queryItems = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        return "/v1/client/billing/" + path + (components.queryItems?.isEmpty == false ? "?" + (components.percentEncodedQuery ?? "") : "")
    }

    private func billingSubscriptionPath(_ action: String, subscriptionId: String?) -> String {
        guard let subscriptionId else { return "/v1/client/billing/subscription/\(action)" }
        let id = subscriptionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? subscriptionId
        return "/v1/client/billing/subscriptions/\(id)/\(action)"
    }

    /// The plans the instance sells, in display order.
    public func billingPlans() async throws -> [BillingPlan] {
        let plans = try await authedDecode(ListEnvelope<BillingPlan>.self, "GET", "/v1/client/billing/plans").data
        return plans.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
    }

    /// The subject's subscription (and add-ons); `orgId` reads an organization's.
    public func billingSubscription(orgId: String? = nil) async throws -> BillingSubscription {
        try await authedDecode(BillingSubscription.self, "GET", billingPath("subscription", [("org_id", orgId)]))
    }

    /// The subject's invoices, newest first.
    public func billingInvoices(orgId: String? = nil) async throws -> [BillingInvoice] {
        try await authedDecode(ListEnvelope<BillingInvoice>.self, "GET", billingPath("invoices", [("org_id", orgId)])).data
    }

    /// The subject's default card, or nil when there is none.
    public func billingPaymentMethod(orgId: String? = nil) async throws -> BillingPaymentMethod? {
        try await authedDecode(BillingPaymentMethodResponse.self, "GET", billingPath("payment_method", [("org_id", orgId)])).paymentMethod
    }

    /// Start a provider Checkout and return its hosted URL; open it in a browser
    /// (``AtlasClient/openInSystemBrowser(_:)`` or `ASWebAuthenticationSession`).
    /// `successURL` / `cancelURL` are where the provider returns, usually your
    /// app's universal link.
    public func billingCheckout(
        planId: String,
        orgId: String? = nil,
        successURL: URL,
        cancelURL: URL,
        interval: String? = nil,
        couponCode: String? = nil
    ) async throws -> URL {
        var body: [String: Any] = ["plan_id": planId, "success_url": successURL.absoluteString, "cancel_url": cancelURL.absoluteString]
        if let orgId { body["org_id"] = orgId }
        if let interval { body["interval"] = interval }
        if let couponCode, !couponCode.isEmpty { body["coupon_code"] = couponCode }
        return try billingURL(try await authedDecode(BillingURLResponse.self, "POST", "/v1/client/billing/checkout", json: body))
    }

    /// Open the provider's Billing Portal (manage card, invoices, cancel) and
    /// return its hosted URL. `subscriptionId` opens that subscription's provider.
    public func billingPortal(returnURL: URL, orgId: String? = nil, subscriptionId: String? = nil) async throws -> URL {
        var body: [String: Any] = ["return_url": returnURL.absoluteString]
        if let orgId { body["org_id"] = orgId }
        if let subscriptionId { body["subscription_id"] = subscriptionId }
        return try billingURL(try await authedDecode(BillingURLResponse.self, "POST", "/v1/client/billing/portal", json: body))
    }

    private func billingURL(_ response: BillingURLResponse) throws -> URL {
        guard let url = URL(string: response.url) else { throw AtlasError.decoding("The server returned no checkout URL.") }
        return url
    }

    /// Switch a live subscription to another plan or interval, with no checkout.
    /// `atPeriodEnd` switches when the period ends instead of now (prorated).
    @discardableResult
    public func billingChangePlan(
        planId: String,
        interval: String? = nil,
        atPeriodEnd: Bool = false,
        orgId: String? = nil,
        subscriptionId: String? = nil
    ) async throws -> BillingSubscription {
        var body: [String: Any] = ["plan_id": planId, "schedule_at_period_end": atPeriodEnd]
        if let orgId { body["org_id"] = orgId }
        if let interval { body["interval"] = interval }
        return try await authedDecode(BillingSubscription.self, "POST", billingSubscriptionPath("change", subscriptionId: subscriptionId), json: body)
    }

    /// Cancel at the end of the period, or now with `immediately`.
    @discardableResult
    public func billingCancel(immediately: Bool = false, orgId: String? = nil, subscriptionId: String? = nil) async throws -> BillingSubscription {
        var body: [String: Any] = ["immediately": immediately]
        if let orgId { body["org_id"] = orgId }
        return try await authedDecode(BillingSubscription.self, "POST", billingSubscriptionPath("cancel", subscriptionId: subscriptionId), json: body)
    }

    /// Undo a cancellation scheduled for the end of the period.
    @discardableResult
    public func billingRestore(orgId: String? = nil, subscriptionId: String? = nil) async throws -> BillingSubscription {
        var body: [String: Any] = [:]
        if let orgId { body["org_id"] = orgId }
        return try await authedDecode(BillingSubscription.self, "POST", billingSubscriptionPath("restore", subscriptionId: subscriptionId), json: body)
    }

    /// May the subject use `feature` (needing `required` units)? For UI only.
    public func billingCheck(feature: String, required: Int? = nil, orgId: String? = nil) async throws -> BillingFeatureCheck {
        try await authedDecode(BillingFeatureCheck.self, "GET", billingPath("check", [
            ("feature", feature), ("required", required.map(String.init)), ("org_id", orgId),
        ]))
    }

    /// Would this discount code work for this plan? For a checkout form's apply button.
    public func billingValidateCoupon(planId: String, code: String, orgId: String? = nil) async throws -> BillingCouponCheck {
        var body: [String: Any] = ["code": code.trimmingCharacters(in: .whitespacesAndNewlines), "plan_id": planId]
        if let orgId { body["org_id"] = orgId }
        return try await authedDecode(BillingCouponCheck.self, "POST", "/v1/client/billing/coupons/validate", json: body)
    }
}
