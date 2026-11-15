// Account-management screens in SwiftUI, mirroring the web components:
// OrganizationSwitcher, PricingTable + BillingOverview, ApiKeys and
// DeviceApproval. They read the instance's dashboard design (`GET /v1/appearance`)
// and the code-level ``AtlasAppearance`` exactly as ``SignIn`` does; with neither,
// they keep plain system styling. Labels are the same English strings as the web
// catalog, so they translate through your app's string catalog.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - theming

/// Resolves the design for a management screen: fetched once, overridden by code.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class AtlasThemeLoader: ObservableObject {
    @Published var info: AtlasAppearanceInfo?
    private var requested = false

    func load(_ client: AtlasClient, preloaded: AtlasAppearanceInfo?) async {
        if let preloaded { info = preloaded; requested = true; return }
        guard !requested else { return }
        requested = true
        info = try? await client.appearance()
    }
}

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasManagementTheme {
    let style: AtlasStyle?

    init(info: AtlasAppearanceInfo?, appearance: AtlasAppearance?, dark: Bool) {
        style = AtlasDesign.resolve(dashboard: info?.design, appearance: appearance)
            .map { AtlasStyle(design: $0, systemIsDark: dark) }
    }

    var text: Color? { style.map { $0.palette.color(.text) } }
    var heading: Font { style?.headingFont ?? .headline }
    var body: Font { style?.bodyFont ?? .body }
    var small: Font { style?.smallFont ?? .footnote }
    var danger: Color { style.map { $0.palette.color(.danger) } ?? .red }
}

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasThemedButton: View {
    let title: LocalizedStringKey
    let theme: AtlasManagementTheme
    var prominent = true
    var destructive = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        if let style = theme.style {
            if prominent {
                Button(action: action) { Text(title) }.buttonStyle(AtlasPrimaryButtonStyle(style: style)).disabled(disabled)
            } else {
                Button(action: action) { Text(title) }.buttonStyle(AtlasSecondaryButtonStyle(style: style, fillWidth: false)).disabled(disabled)
            }
        } else if prominent {
            Button(role: destructive ? .destructive : nil, action: action) { Text(title) }.buttonStyle(.borderedProminent).disabled(disabled)
        } else {
            Button(role: destructive ? .destructive : nil, action: action) { Text(title) }.buttonStyle(.bordered).disabled(disabled)
        }
    }
}

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
private struct AtlasErrorLine: View {
    let message: String?
    let theme: AtlasManagementTheme
    var body: some View {
        if let message { Text(message).font(theme.small).foregroundColor(theme.danger) }
    }
}

private func atlasMessage(_ error: Error) -> String {
    if let e = error as? AtlasError {
        switch e {
        case let .api(_, errors): return errors.first?.message ?? "Something went wrong."
        case let .transport(m), let .decoding(m): return m
        case .notSignedIn: return "Not signed in."
        }
    }
    return error.localizedDescription
}

// MARK: - organization switcher

/// Lists the user's organizations, switches the active one for the session and
/// creates a new one. ``activeOrganizationId`` follows the session token.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public final class OrganizationSwitcherModel: ObservableObject {
    @Published public private(set) var memberships: [OrganizationMembership] = []
    @Published public private(set) var activeOrganizationId: String?
    @Published public private(set) var isLoaded = false
    @Published public private(set) var isBusy = false
    @Published public var message: String?

    let client: AtlasClient
    public init(client: AtlasClient) { self.client = client }

    public func load() async {
        do {
            memberships = try await client.organizations()
            activeOrganizationId = client.activeOrganizationId()
            message = nil
        } catch { message = atlasMessage(error) }
        isLoaded = true
    }

    /// Switch the active organization; nil selects the personal account.
    public func select(_ organizationId: String?) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.setActiveOrganization(organizationId)
            activeOrganizationId = organizationId
            message = nil
        } catch { message = atlasMessage(error) }
    }

    /// Create an organization and make it active.
    @discardableResult
    public func create(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let org = try await client.createOrganization(name: trimmed, slug: OrganizationSwitcherModel.slug(trimmed))
            _ = try await client.setActiveOrganization(org.id)
            memberships = try await client.organizations()
            activeOrganizationId = org.id
            message = nil
            return true
        } catch { message = atlasMessage(error); return false }
    }

    /// `Acme Corp` becomes `acme-corp`; letters and digits only, dashes between.
    public static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) } else if out.last != "-" { out.append("-") }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct OrganizationSwitcher: View {
    @StateObject private var model: OrganizationSwitcherModel
    @StateObject private var themeLoader = AtlasThemeLoader()
    @Environment(\.colorScheme) private var scheme
    @State private var creating = false
    @State private var newName = ""
    private let appearance: AtlasAppearance?
    private let appearanceInfo: AtlasAppearanceInfo?
    private let allowCreate: Bool
    private let onChange: ((String?) -> Void)?

    /// - Parameters:
    ///   - allowCreate: show "or create a new organization" (the instance must allow it).
    ///   - onChange: called with the new active organization id (nil = personal).
    public init(
        session: AtlasAuthSession,
        appearance: AtlasAppearance? = nil,
        appearanceInfo: AtlasAppearanceInfo? = nil,
        allowCreate: Bool = true,
        onChange: ((String?) -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: OrganizationSwitcherModel(client: session.client))
        self.appearance = appearance
        self.appearanceInfo = appearanceInfo
        self.allowCreate = allowCreate
        self.onChange = onChange
    }

    private var theme: AtlasManagementTheme {
        AtlasManagementTheme(info: themeLoader.info, appearance: appearance, dark: scheme == .dark)
    }

    private var activeName: String {
        model.memberships.first { $0.organization.id == model.activeOrganizationId }?.organization.name ?? "Personal account"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
            #if os(watchOS)
            // Menu is unavailable on watchOS: list the choices inline.
            VStack(alignment: .leading, spacing: 8) {
                Button { pick(nil) } label: { check("Personal account", model.activeOrganizationId == nil) }
                ForEach(model.memberships, id: \.organization.id) { m in
                    Button { pick(m.organization.id) } label: { check(m.organization.name, m.organization.id == model.activeOrganizationId) }
                }
                if allowCreate {
                    Divider()
                    Button("or create a new organization") { creating = true }
                }
            }
            #else
            Menu {
                Button { pick(nil) } label: { check("Personal account", model.activeOrganizationId == nil) }
                ForEach(model.memberships, id: \.organization.id) { m in
                    Button { pick(m.organization.id) } label: { check(m.organization.name, m.organization.id == model.activeOrganizationId) }
                }
                if allowCreate {
                    Divider()
                    Button("or create a new organization") { creating = true }
                }
            } label: {
                Label(activeName, systemImage: "building.2").font(theme.body).foregroundColor(theme.text)
            }
            #endif
            }
            .accessibilityLabel("Switch organization")
            .disabled(model.isBusy)
            AtlasErrorLine(message: model.message, theme: theme)
        }
        .task {
            await themeLoader.load(model.client, preloaded: appearanceInfo)
            await model.load()
        }
        .sheet(isPresented: $creating) { createSheet }
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func pick(_ id: String?) {
        Task {
            await model.select(id)
            if model.message == nil { onChange?(id) }
        }
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create organization").font(theme.heading).foregroundColor(theme.text)
            TextField("Organization name", text: $newName).modifier(AtlasPlatformFieldStyle())
            AtlasErrorLine(message: model.message, theme: theme)
            HStack {
                AtlasThemedButton(title: "Cancel", theme: theme, prominent: false) { creating = false }
                AtlasThemedButton(title: "Create organization", theme: theme, disabled: model.isBusy || newName.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task {
                        if await model.create(name: newName) { creating = false; newName = ""; onChange?(model.activeOrganizationId) }
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - billing

/// Plans, the subject's subscription, invoices and card. Checkout and the
/// Billing Portal open the provider's hosted pages (`openURL`).
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public final class BillingModel: ObservableObject {
    @Published public private(set) var plans: [BillingPlan] = []
    @Published public private(set) var subscription: BillingSubscription?
    @Published public private(set) var invoices: [BillingInvoice] = []
    @Published public private(set) var paymentMethod: BillingPaymentMethod?
    @Published public private(set) var isLoaded = false
    @Published public private(set) var busyPlanId: String?
    @Published public var message: String?

    let client: AtlasClient
    public let orgId: String?
    public let returnURL: URL

    /// - Parameters:
    ///   - orgId: bill an organization the user administers instead of the user.
    ///   - returnURL: where the provider sends the user back (your universal link).
    public init(client: AtlasClient, orgId: String? = nil, returnURL: URL) {
        self.client = client
        self.orgId = orgId
        self.returnURL = returnURL
    }

    public func load() async {
        do {
            plans = try await client.billingPlans()
            subscription = try? await client.billingSubscription(orgId: orgId)
            invoices = (try? await client.billingInvoices(orgId: orgId)) ?? []
            paymentMethod = (try? await client.billingPaymentMethod(orgId: orgId)) ?? nil
            message = nil
        } catch { message = atlasMessage(error) }
        isLoaded = true
    }

    /// Buy a plan, or switch in place when a base subscription is already live.
    /// Returns the hosted Checkout URL to open, or nil when the plan was switched.
    public func subscribe(_ plan: BillingPlan, interval: String?) async -> URL? {
        busyPlanId = plan.id
        defer { busyPlanId = nil }
        do {
            if plan.kind != "addon", subscription?.isLive == true, subscription?.plan?.kind != "addon", subscription?.plan != nil {
                subscription = try await client.billingChangePlan(planId: plan.id, interval: interval, orgId: orgId)
                message = nil
                return nil
            }
            message = nil
            return try await client.billingCheckout(
                planId: plan.id, orgId: orgId, successURL: returnURL, cancelURL: returnURL,
                interval: plan.annualAvailable ? interval : nil
            )
        } catch { message = atlasMessage(error); return nil }
    }

    public func portalURL(subscriptionId: String? = nil) async -> URL? {
        do {
            message = nil
            return try await client.billingPortal(returnURL: returnURL, orgId: orgId, subscriptionId: subscriptionId)
        } catch { message = atlasMessage(error); return nil }
    }

    public func cancel() async { await mutate { self.subscription = try await self.client.billingCancel(orgId: self.orgId) } }
    public func restore() async { await mutate { self.subscription = try await self.client.billingRestore(orgId: self.orgId) } }

    private func mutate(_ work: () async throws -> Void) async {
        do { try await work(); message = nil } catch { message = atlasMessage(error) }
    }
}

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct PricingTable: View {
    @StateObject private var model: BillingModel
    @StateObject private var themeLoader = AtlasThemeLoader()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var interval = "month"
    private let appearance: AtlasAppearance?
    private let appearanceInfo: AtlasAppearanceInfo?
    private let audience: String?
    private let locale: Locale

    /// - Parameter audience: `user` or `org` to show only those plans.
    public init(
        session: AtlasAuthSession,
        returnURL: URL,
        orgId: String? = nil,
        audience: String? = nil,
        locale: Locale = .current,
        appearance: AtlasAppearance? = nil,
        appearanceInfo: AtlasAppearanceInfo? = nil
    ) {
        _model = StateObject(wrappedValue: BillingModel(client: session.client, orgId: orgId, returnURL: returnURL))
        self.audience = audience
        self.locale = locale
        self.appearance = appearance
        self.appearanceInfo = appearanceInfo
    }

    private var theme: AtlasManagementTheme {
        AtlasManagementTheme(info: themeLoader.info, appearance: appearance, dark: scheme == .dark)
    }

    public var body: some View {
        let shown = model.plans.filter { audience == nil || $0.audience == audience }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if shown.contains(where: { $0.annualAvailable }) {
                    Picker("Billing interval", selection: $interval) {
                        Text("Monthly").tag("month")
                        Text("Yearly").tag("year")
                    }
                    #if !os(watchOS)
                    .pickerStyle(.segmented)
                    #endif
                }
                ForEach(shown, id: \.id) { plan in card(plan) }
                AtlasErrorLine(message: model.message, theme: theme)
            }.padding()
        }
        .task {
            await themeLoader.load(model.client, preloaded: appearanceInfo)
            await model.load()
        }
    }

    @ViewBuilder private func card(_ plan: BillingPlan) -> some View {
        let isAddon = plan.kind == "addon"
        let held = model.subscription?.liveAddons.first { $0.plan?.id == plan.id }
        let current = isAddon ? held != nil : plan.id == model.subscription?.plan?.id
        let view = plan.priceView(interval: interval, locale: locale)
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.name).font(theme.heading).foregroundColor(theme.text)
            if let badge = plan.badge { Text(badge).font(theme.small).foregroundColor(.accentColor) }
            if let d = plan.description { Text(d).font(theme.body).foregroundColor(theme.text) }
            if let promo = view.promotionLabel { Text(promo).font(theme.small).foregroundColor(.accentColor) }
            HStack(spacing: 4) {
                if let original = view.originalPrice { Text(original).strikethrough().font(theme.small) }
                Text(view.free ? "Free" : view.price).font(theme.heading).foregroundColor(theme.text)
                if !view.free { Text("/ \(view.interval == "year" ? "year" : "month")").font(theme.small) }
            }
            if let days = view.trialDays { Text("\(days)-day free trial").font(theme.small) }
            if let code = view.promotionCode { Text("Use code \(code) at checkout").font(theme.small) }
            ForEach(plan.features, id: \.self) { f in Label(f, systemImage: "checkmark").font(theme.body) }
            if current {
                AtlasThemedButton(title: "Manage billing", theme: theme) {
                    Task { if let url = await model.portalURL(subscriptionId: held?.id) { openURL(url) } }
                }
            } else {
                AtlasThemedButton(title: "Subscribe", theme: theme, disabled: model.busyPlanId == plan.id) {
                    Task {
                        if let url = await model.subscribe(plan, interval: interval) { openURL(url) } else { await model.load() }
                    }
                }
            }
        }
        .padding()
        .overlay(RoundedRectangle(cornerRadius: CGFloat(theme.style?.controlRadius ?? 12)).stroke(current ? Color.accentColor : Color.secondary.opacity(0.3)))
        .accessibilityElement(children: .contain)
    }
}

/// The subscription's status, the card on file, a Manage billing button and the
/// invoice history.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct BillingOverview: View {
    @StateObject private var model: BillingModel
    @StateObject private var themeLoader = AtlasThemeLoader()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    private let appearance: AtlasAppearance?
    private let appearanceInfo: AtlasAppearanceInfo?

    public init(
        session: AtlasAuthSession,
        returnURL: URL,
        orgId: String? = nil,
        appearance: AtlasAppearance? = nil,
        appearanceInfo: AtlasAppearanceInfo? = nil
    ) {
        _model = StateObject(wrappedValue: BillingModel(client: session.client, orgId: orgId, returnURL: returnURL))
        self.appearance = appearance
        self.appearanceInfo = appearanceInfo
    }

    private var theme: AtlasManagementTheme {
        AtlasManagementTheme(info: themeLoader.info, appearance: appearance, dark: scheme == .dark)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let sub = model.subscription, let status = sub.status {
                    Text(sub.plan?.name ?? "Subscription").font(theme.heading).foregroundColor(theme.text)
                    Text(status.replacingOccurrences(of: "_", with: " ").capitalized).font(theme.small)
                    if let end = sub.currentPeriodEnd {
                        let date = Date(timeIntervalSince1970: end / 1000).formatted(date: .abbreviated, time: .omitted)
                        Text(sub.cancelAtPeriodEnd ? "Ends \(date)" : "Renews \(date)").font(theme.small)
                    }
                    if let card = model.paymentMethod {
                        Text("\(card.brand.capitalized) ending \(card.last4), expires \(card.expMonth)/\(card.expYear)").font(theme.small)
                    }
                    HStack {
                        AtlasThemedButton(title: "Manage billing", theme: theme) {
                            Task { if let url = await model.portalURL() { openURL(url) } }
                        }
                        if sub.isLive {
                            if sub.cancelAtPeriodEnd {
                                AtlasThemedButton(title: "Resume subscription", theme: theme, prominent: false) { Task { await model.restore() } }
                            } else {
                                AtlasThemedButton(title: "Cancel subscription", theme: theme, prominent: false, destructive: true) { Task { await model.cancel() } }
                            }
                        }
                    }
                } else if model.isLoaded {
                    Text("No subscription yet.").font(theme.body)
                }
                Text("Invoices").font(theme.heading).foregroundColor(theme.text)
                if model.invoices.isEmpty && model.isLoaded {
                    Text("No invoices yet.").font(theme.body)
                }
                ForEach(model.invoices, id: \.id) { inv in
                    HStack {
                        Text(inv.number ?? inv.id).font(theme.body)
                        Spacer()
                        Text(BillingPlan.formatMoney(inv.amountDue, currency: inv.currency)).font(theme.body)
                        Text(inv.status).font(theme.small)
                        if let link = inv.hostedInvoiceURL.flatMap(URL.init(string:)) {
                            Button("View") { openURL(link) }
                        }
                    }
                }
                AtlasErrorLine(message: model.message, theme: theme)
            }.padding()
        }
        .task {
            await themeLoader.load(model.client, preloaded: appearanceInfo)
            await model.load()
        }
    }
}

// MARK: - API keys

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public final class ApiKeysModel: ObservableObject {
    public enum Status: Equatable { case loading, ready, disabled, failed }
    @Published public private(set) var status: Status = .loading
    @Published public private(set) var list = UserApiKeyList.empty
    @Published public var message: String?
    /// Set when the last create needs a fresh re-authentication.
    @Published public var needsStepUp = false
    /// The one-time secret of the key just created; clear it once copied.
    @Published public var createdSecret: String?

    let client: AtlasClient
    public let organizationId: String?
    private var parked: (name: String?, expiresInSeconds: Int?, scopes: [String]?)?

    public init(client: AtlasClient, organizationId: String? = nil) {
        self.client = client
        self.organizationId = organizationId
    }

    public func load() async {
        do {
            list = try await client.apiKeys(organizationId: organizationId)
            status = .ready
            message = nil
        } catch let e as AtlasError {
            if case let .api(code, _) = e, code == 403 { status = .disabled } else { status = .failed }
            message = atlasMessage(e)
        } catch { status = .failed; message = atlasMessage(error) }
    }

    public func create(name: String?, expiresInDays: Int?, scopes: [String]?) async {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        await attemptCreate(name: (trimmed?.isEmpty ?? true) ? nil : trimmed, expiresInSeconds: expiresInDays.map { $0 * 86_400 }, scopes: scopes)
    }

    private func attemptCreate(name: String?, expiresInSeconds: Int?, scopes: [String]?) async {
        do {
            let created = try await client.createApiKey(
                name: name, expiresInSeconds: expiresInSeconds, scopes: scopes, organizationId: organizationId
            )
            createdSecret = created.secret
            needsStepUp = false
            parked = nil
            message = nil
            await load()
        } catch let e as AtlasError where e.isStepUpRequired {
            parked = (name, expiresInSeconds, scopes)
            needsStepUp = true
        } catch { message = atlasMessage(error) }
    }

    /// Re-authenticate with the password, then finish the parked create.
    public func completeStepUp(password: String) async {
        do {
            try await client.stepUp(strategy: "password", password: password)
        } catch { message = atlasMessage(error); return }
        if let p = parked { await attemptCreate(name: p.name, expiresInSeconds: p.expiresInSeconds, scopes: p.scopes) }
    }

    public func rename(_ key: UserApiKey, to name: String) async {
        do { _ = try await client.renameApiKey(id: key.id, name: name.isEmpty ? nil : name); await load() } catch { message = atlasMessage(error) }
    }

    public func revoke(_ key: UserApiKey) async {
        do { try await client.revokeApiKey(id: key.id); await load() } catch { message = atlasMessage(error) }
    }
}

extension UserApiKeyList {
    static let empty = try! JSONDecoder().decode(UserApiKeyList.self, from: Data("{}".utf8))
}

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct ApiKeys: View {
    @StateObject private var model: ApiKeysModel
    @StateObject private var themeLoader = AtlasThemeLoader()
    @Environment(\.colorScheme) private var scheme
    @State private var creating = false
    @State private var name = ""
    @State private var expiresDays = 0
    @State private var picked: Set<String> = []
    @State private var password = ""
    @State private var revoking: UserApiKey?
    @State private var renaming: UserApiKey?
    @State private var renameText = ""
    private let appearance: AtlasAppearance?
    private let appearanceInfo: AtlasAppearanceInfo?

    /// - Parameter organizationId: manage the organization's keys instead of the user's.
    public init(
        session: AtlasAuthSession,
        organizationId: String? = nil,
        appearance: AtlasAppearance? = nil,
        appearanceInfo: AtlasAppearanceInfo? = nil
    ) {
        _model = StateObject(wrappedValue: ApiKeysModel(client: session.client, organizationId: organizationId))
        self.appearance = appearance
        self.appearanceInfo = appearanceInfo
    }

    private var theme: AtlasManagementTheme {
        AtlasManagementTheme(info: themeLoader.info, appearance: appearance, dark: scheme == .dark)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("API keys").font(theme.heading).foregroundColor(theme.text)
                Text(model.organizationId == nil
                     ? "Keys let scripts and integrations act as you. Treat them like passwords."
                     : "Keys let scripts and integrations act as this organization. Treat them like passwords.")
                    .font(theme.small)
                if model.status == .disabled {
                    Text("API keys are not available for this account.").font(theme.body)
                } else {
                    content
                }
                if model.status != .disabled { AtlasErrorLine(message: model.message, theme: theme) }
            }.padding()
        }
        .task {
            await themeLoader.load(model.client, preloaded: appearanceInfo)
            await model.load()
        }
        .sheet(isPresented: $creating) { createForm }
        .alert("Copy your new key", isPresented: Binding(get: { model.createdSecret != nil }, set: { if !$0 { model.createdSecret = nil } })) {
            Button("Copy") { copy(model.createdSecret ?? ""); model.createdSecret = nil }
            Button("Done", role: .cancel) { model.createdSecret = nil }
        } message: {
            Text("\(model.createdSecret ?? "")\n\nThis is the only time it will be shown. If you lose it, revoke it and create another.")
        }
        .alert("Revoke this key? Anything using it will stop working.", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Yes, revoke", role: .destructive) { if let k = revoking { Task { await model.revoke(k) } }; revoking = nil }
            Button("Cancel", role: .cancel) { revoking = nil }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let k = renaming { Task { await model.rename(k, to: renameText) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var atLimit: Bool { model.list.maxActiveKeys > 0 && model.list.activeCount >= model.list.maxActiveKeys }

    @ViewBuilder private var content: some View {
        if model.list.keys.isEmpty && model.status == .ready { Text("No API keys yet.").font(theme.body) }
        ForEach(model.list.keys, id: \.id) { key in
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name ?? "Unnamed key").font(theme.body).foregroundColor(theme.text)
                Text(key.prefix).font(.system(.footnote, design: .monospaced))
                Text(status(of: key)).font(theme.small)
                if key.isActive() {
                    HStack {
                        AtlasThemedButton(title: "Rename", theme: theme, prominent: false) { renameText = key.name ?? ""; renaming = key }
                        AtlasThemedButton(title: "Revoke", theme: theme, prominent: false, destructive: true) { revoking = key }
                    }
                }
            }
        }
        if atLimit {
            Text("You've reached the maximum of \(model.list.maxActiveKeys) active keys. Revoke one to create another.").font(theme.small)
        }
        AtlasThemedButton(title: "Create key", theme: theme, disabled: atLimit) { creating = true }
    }

    private func status(of key: UserApiKey) -> String {
        if key.revokedAt != nil { return "Revoked" }
        if !key.isActive() { return "Expired" }
        let used = key.lastUsedAt.map { "Last used \(Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .omitted))" } ?? "Never used"
        if let exp = key.expiresAt { return used + " · Expires \(Date(timeIntervalSince1970: exp / 1000).formatted(date: .abbreviated, time: .omitted))" }
        return used
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create key").font(theme.heading).foregroundColor(theme.text)
            TextField("e.g. CI pipeline", text: $name).modifier(AtlasPlatformFieldStyle())
            Picker("Expires", selection: $expiresDays) {
                Text("Never").tag(0)
                Text("In 30 days").tag(30)
                Text("In 90 days").tag(90)
                Text("In 365 days").tag(365)
            }
            if !model.list.allowedScopes.isEmpty {
                Text("Scopes").font(theme.small)
                ForEach(model.list.allowedScopes, id: \.self) { scope in
                    Toggle(scope, isOn: Binding(get: { picked.contains(scope) }, set: { if $0 { picked.insert(scope) } else { picked.remove(scope) } }))
                }
            }
            if model.needsStepUp {
                Text("Enter your password to confirm.").font(theme.small)
                SecureField("Password", text: $password).modifier(AtlasPlatformFieldStyle())
            }
            AtlasErrorLine(message: model.message, theme: theme)
            HStack {
                AtlasThemedButton(title: "Cancel", theme: theme, prominent: false) { creating = false; model.needsStepUp = false }
                AtlasThemedButton(title: model.needsStepUp ? "Confirm" : "Create key", theme: theme, disabled: model.needsStepUp && password.isEmpty) {
                    Task {
                        if model.needsStepUp { await model.completeStepUp(password: password) }
                        else { await model.create(name: name, expiresInDays: expiresDays == 0 ? nil : expiresDays, scopes: picked.isEmpty ? nil : picked.sorted()) }
                        if !model.needsStepUp && model.message == nil { creating = false; name = ""; password = ""; picked = [] }
                    }
                }
            }
        }
        .padding()
    }

    private func copy(_ text: String) {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - device approval

/// Approve (or deny) the code a TV, console or CLI shows. A QR code that carries
/// `?user_code=` can be handed to ``DeviceApprovalModel/lookup(_:)`` through
/// ``AtlasClient/userCodeFromURL(_:)``.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public final class DeviceApprovalModel: ObservableObject {
    public enum Phase: Equatable { case entering, pending(PendingDeviceAuthorization), approved, denied }
    @Published public private(set) var phase: Phase = .entering
    @Published public var message: String?
    @Published public var needsStepUp = false
    @Published public private(set) var isBusy = false

    let client: AtlasClient
    public init(client: AtlasClient) { self.client = client }

    public func lookup(_ input: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            phase = .pending(try await client.lookupDeviceAuthorization(userCode: input))
            message = nil
        } catch { message = "That code is not valid. It may have expired or already been used." }
    }

    public func decide(approve: Bool) async {
        guard case let .pending(auth) = phase else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if approve { try await client.approveDeviceAuthorization(auth) } else { try await client.denyDeviceAuthorization(auth) }
            phase = approve ? .approved : .denied
            message = nil
            needsStepUp = false
        } catch let e as AtlasError where e.isStepUpRequired {
            needsStepUp = true
        } catch { message = atlasMessage(error) }
    }

    public func completeStepUp(password: String) async {
        do { try await client.stepUp(strategy: "password", password: password) } catch { message = atlasMessage(error); return }
        await decide(approve: true)
    }

    public func reset() { phase = .entering; message = nil; needsStepUp = false }
}

@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct DeviceApproval: View {
    @StateObject private var model: DeviceApprovalModel
    @StateObject private var themeLoader = AtlasThemeLoader()
    @Environment(\.colorScheme) private var scheme
    @State private var code: String
    @State private var password = ""
    private let appearance: AtlasAppearance?
    private let appearanceInfo: AtlasAppearanceInfo?

    /// - Parameter userCode: a code already known (e.g. from a scanned URL); looked up on appear.
    public init(
        session: AtlasAuthSession,
        userCode: String? = nil,
        appearance: AtlasAppearance? = nil,
        appearanceInfo: AtlasAppearanceInfo? = nil
    ) {
        _model = StateObject(wrappedValue: DeviceApprovalModel(client: session.client))
        _code = State(initialValue: userCode ?? "")
        self.appearance = appearance
        self.appearanceInfo = appearanceInfo
    }

    private var theme: AtlasManagementTheme {
        AtlasManagementTheme(info: themeLoader.info, appearance: appearance, dark: scheme == .dark)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in on a device").font(theme.heading).foregroundColor(theme.text)
            switch model.phase {
            case .entering:
                Text("Enter the code shown on your TV, console or terminal.").font(theme.small)
                TextField("Code", text: $code).modifier(AtlasPlatformFieldStyle())
                    .onChange(of: code) { code = AtlasClient.formatUserCode($0) }
                AtlasThemedButton(title: "Continue", theme: theme, disabled: model.isBusy || code.isEmpty) { Task { await model.lookup(code) } }
            case let .pending(auth):
                Text("\(auth.client.name) wants to sign in to your account on a device.").font(theme.body)
                if !auth.scopes.isEmpty {
                    Text("It will be able to:").font(theme.small)
                    ForEach(auth.scopes, id: \.scope) { s in Label(s.description.isEmpty ? s.scope : s.description, systemImage: "checkmark").font(theme.body) }
                }
                Text("Only continue if your device shows this code: \(auth.userCode)").font(theme.small)
                if model.needsStepUp {
                    Text("Enter your password to confirm.").font(theme.small)
                    SecureField("Password", text: $password).modifier(AtlasPlatformFieldStyle())
                }
                HStack {
                    AtlasThemedButton(title: "Deny", theme: theme, prominent: false, destructive: true, disabled: model.isBusy) { Task { await model.decide(approve: false) } }
                    AtlasThemedButton(title: "Allow", theme: theme, disabled: model.isBusy || (model.needsStepUp && password.isEmpty)) {
                        Task { if model.needsStepUp { await model.completeStepUp(password: password) } else { await model.decide(approve: true) } }
                    }
                }
            case .approved:
                Text("Your device is signed in. You can go back to it now.").font(theme.body)
                AtlasThemedButton(title: "Enter another code", theme: theme, prominent: false) { code = ""; model.reset() }
            case .denied:
                Text("Sign-in denied. Nothing was shared with the device.").font(theme.body)
                AtlasThemedButton(title: "Enter another code", theme: theme, prominent: false) { code = ""; model.reset() }
            }
            AtlasErrorLine(message: model.message, theme: theme)
        }
        .padding()
        .task {
            await themeLoader.load(model.client, preloaded: appearanceInfo)
            if !code.isEmpty, model.phase == .entering { await model.lookup(code) }
        }
    }
}
#endif
