// The prebuilt SwiftUI sign-up screen, native on iOS 15+, macOS 12+, visionOS 1+,
// tvOS 17+ and watchOS 10+. Email and password, the instance's policies (terms of
// service, privacy, …) as checkbox / clickwrap / unskippable-scroll rows, the
// emailed code, and the "accept to continue" step for a sign-up the server holds.
#if canImport(SwiftUI)
import SwiftUI
import Combine

/// The view-model behind ``SignUp``: it owns the ``SignUpFlow`` and the policy
/// state, and republishes the step and errors as `@Published` state.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class SignUpModel: ObservableObject {
    @Published var step: SignInStep = .collectIdentifier
    @Published var email = ""
    @Published var password = ""
    @Published var code = ""
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var completed = false
    @Published var appearanceInfo: AtlasAppearanceInfo?
    /// The legacy single legal checkbox, when the instance has no policies but wants one.
    @Published var legacy: AtlasPolicies.LegacyConsent?
    @Published var legacyTicked = false

    /// The policies the sign-up form (or the held step) asks for.
    let policy = PolicyAcceptanceModel()

    private let session: AtlasAuthSession
    private var flow: SignUpFlow
    private var appearanceRequested: Bool
    private var policyChanges: AnyCancellable?

    init(session: AtlasAuthSession, appearanceInfo: AtlasAppearanceInfo? = nil) {
        self.session = session
        self.flow = session.client.signUpFlow()
        self.appearanceInfo = appearanceInfo
        self.appearanceRequested = appearanceInfo != nil
        // The submit button depends on the ticks held by the nested policy model.
        self.policyChanges = policy.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func loadAppearance() async {
        guard !appearanceRequested else { return }
        appearanceRequested = true
        if let info = try? await session.client.appearance() { appearanceInfo = info }
    }

    /// Fetch the instance's policies. A failed fetch is not fatal: the server
    /// refuses a sign-up that lacks a required one and the form reloads then.
    func loadPolicies() async {
        guard !policy.isLoaded else { return }
        do {
            let list = try await session.client.policies()
            policy.load(list.policies)
            legacy = list.policies.isEmpty ? list.legacyConsent : nil
        } catch {
            policy.load([])
        }
    }

    /// Whether the submit button may be enabled.
    var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && policy.state.canSubmit
            && !(legacy?.required == true && !legacyTicked)
    }

    /// Submit the form: show each unskippable document first, then create the account.
    func submit() {
        guard !busy else { return }
        policy.beginSubmit { [weak self] acceptances in
            guard let self else { return }
            Task { await self.start(acceptances) }
        }
    }

    private func start(_ acceptances: [PolicyAcceptance]) async {
        let consent: Bool? = (legacy != nil && legacyTicked) ? true : nil
        await drive {
            try await self.flow.start(
                email: self.email, password: self.password, consent: consent,
                policyAcceptances: acceptances
            )
        }
        await reloadIfPolicyRefused()
    }

    func submitCode() async { await drive { try await self.flow.attemptVerification(code: self.code) } }
    func resendCode() async { await drive { try await self.flow.prepareVerification() } }

    /// Send the acceptances for a sign-up the server holds for policies.
    func acceptPolicies(_ acceptances: [PolicyAcceptance]) async {
        await drive { try await self.flow.acceptPolicies(acceptances) }
        await reloadIfPolicyRefused()
    }

    /// The user declined: abandon this sign-up and start over.
    func declinePolicies() {
        let title = policy.state.policies.first?.title ?? "required policies"
        reset()
        errorMessage = PolicyText.declined(title)
    }

    func reset() {
        flow = session.client.signUpFlow()
        step = .collectIdentifier
        code = ""; password = ""; errorMessage = nil; completed = false
        policy.reset()
        Task { await loadPolicies() }
    }

    /// A 422 `POLICY_ACCEPTANCE_REQUIRED` means a policy changed under the form:
    /// show what is needed now.
    private func reloadIfPolicyRefused() async {
        guard refusedForPolicy else { return }
        refusedForPolicy = false
        if case let .acceptPolicies(pending) = step {
            if let fresh = try? await session.client.policies(resolving: pending) { policy.load(fresh) }
        } else if let list = try? await session.client.policies() {
            policy.load(list.policies)
        }
    }

    private var refusedForPolicy = false

    private func publish(_ next: SignInStep) async {
        step = next
        switch next {
        case let .acceptPolicies(pending):
            policy.reset()
            let held = await flow.pendingPolicies
            do {
                policy.load(try await session.client.policies(resolving: pending.isEmpty ? held : pending))
            } catch {
                present(error)
                policy.load([])
            }
        case .done:
            completed = true
            await session.reload()
        default:
            break
        }
    }

    private func present(_ error: Error) {
        if let error = error as? AtlasError {
            errorMessage = error.message
            if error.isPolicyAcceptanceRequired { refusedForPolicy = true }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func drive(_ work: @escaping () async throws -> SignInStep) async {
        busy = true
        errorMessage = nil
        do {
            await publish(try await work())
        } catch {
            present(error)
        }
        busy = false
    }
}

/// A drop-in sign-up screen: email and password with the instance's policies,
/// then the emailed code. A sign-up the server holds for a policy (a social
/// sign-up that still owes one) shows the "accept to continue" step.
///
/// **Policies.** The instance's policies are read on appear
/// (`GET /v1/client/policies`) and shown by their display mode: a checkbox (the
/// names open the document in place), clickwrap text under the button, or an
/// unskippable document shown on submit whose Accept enables once the end is
/// visible. Without policies, an instance's single legacy legal checkbox is shown
/// when configured.
///
/// **Per platform.** The form on iOS, iPadOS, macOS and visionOS; a centred
/// column on tvOS (text links are not focusable there, so each policy has a Read
/// button and the sheets scroll with the remote); a scrolling list on watchOS
/// (the digital crown scrolls policy documents).
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct SignUp: View {
    @StateObject private var model: SignUpModel
    @Environment(\.colorScheme) private var systemScheme
    private let onComplete: () -> Void
    private let appearance: AtlasAppearance?

    /// - Parameters:
    ///   - session: the session to refresh when sign-up completes.
    ///   - appearance: code-level design overrides (win over the dashboard design).
    ///   - appearanceInfo: a pre-fetched ``AtlasAppearanceInfo``.
    ///   - onComplete: called after the session is established.
    public init(
        session: AtlasAuthSession,
        appearance: AtlasAppearance? = nil,
        appearanceInfo: AtlasAppearanceInfo? = nil,
        onComplete: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: SignUpModel(session: session, appearanceInfo: appearanceInfo))
        self.appearance = appearance
        self.onComplete = onComplete
    }

    private var style: AtlasStyle? {
        AtlasDesign.resolve(dashboard: model.appearanceInfo?.design, appearance: appearance)
            .map { AtlasStyle(design: $0, systemIsDark: systemScheme == .dark) }
    }

    public var body: some View {
        platformBody
            .onChange(of: model.completed) { done in if done { onComplete() } }
            .task { await model.loadAppearance() }
            .task { await model.loadPolicies() }
    }

    @ViewBuilder private var platformBody: some View {
        #if os(watchOS)
        ScrollView {
            VStack(alignment: .leading, spacing: style?.gap ?? 10) { content(style) }
                .foregroundColor(style.map { $0.palette.color(.text) })
        }
        #elseif os(tvOS)
        VStack(alignment: .leading, spacing: style?.gap ?? 28) { content(style) }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(60)
        #else
        if let style {
            VStack(alignment: .leading, spacing: style.gap) { content(style) }
                .foregroundColor(style.palette.color(.text))
                .modifier(AtlasCardModifier(style: style, systemIsDark: systemScheme == .dark))
        } else {
            VStack(alignment: .leading, spacing: 16) { content(nil) }.padding()
        }
        #endif
    }

    @ViewBuilder private func content(_ style: AtlasStyle?) -> some View {
        heading("Create your account", style)
        stepContent(style)
        status(style)
    }

    @ViewBuilder private func stepContent(_ style: AtlasStyle?) -> some View {
        switch model.step {
        case .collectIdentifier, .collectFirstFactor:
            field("Email", text: $model.email, style)
            secureField("Password", text: $model.password, style)
            if !model.policy.isLoaded {
                ProgressView()
            } else {
                if let legacy = model.legacy { legacyRow(legacy, style) }
                AtlasPolicyConsent(model: model.policy, style: style)
            }
            primaryButton("Create account", style, enabled: model.canSubmit) { model.submit() }

        case .collectEmailCode, .collectPhoneCode:
            caption("Enter the code we sent you.", style)
            field("Verification code", text: $model.code, style)
            primaryButton("Verify", style, enabled: !model.code.isEmpty) { Task { await model.submitCode() } }
            secondaryButton("Send a new code", style) { Task { await model.resendCode() } }

        case .acceptPolicies:
            AtlasPolicyAcceptStep(
                policy: model.policy,
                style: style,
                busy: model.busy,
                onAccept: { acceptances in Task { await model.acceptPolicies(acceptances) } },
                onDecline: { model.declinePolicies() }
            )

        case .done:
            caption("Your account is ready.", style)

        case let .restart(reason):
            caption("This sign-up was \(reason). Start again.", style)
            secondaryButton("Start over", style) { model.reset() }

        case .awaitOAuth, .collectCaptcha:
            caption("Continue in your browser to finish signing up.", style)

        case .collectSecondFactor, .enrollSecondFactor, .collectNewPassword:
            caption("Finish this step in the sign-in screen.", style)

        case let .unknown(status):
            caption("This sign-up needs an app update (\(status)).", style)
        }
    }

    // MARK: pieces

    @ViewBuilder private func legacyRow(_ legacy: AtlasPolicies.LegacyConsent, _ style: AtlasStyle?) -> some View {
        Button { model.legacyTicked.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.legacyTicked ? "checkmark.square.fill" : "square")
                Text("I agree to the Terms of Service and Privacy Policy")
                    .multilineTextAlignment(.leading)
            }
        }
        .font(style?.smallFont ?? .footnote)
        .accessibilityValue(model.legacyTicked ? "Checked" : "Unchecked")
        #if !os(tvOS) && !os(watchOS)
        .buttonStyle(.plain)
        #endif
        if let raw = legacy.termsURL, let url = URL(string: raw) {
            Link("Read the Terms of Service", destination: url).font(style?.smallFont ?? .footnote)
        }
        if let raw = legacy.privacyURL, let url = URL(string: raw) {
            Link("Read the Privacy Policy", destination: url).font(style?.smallFont ?? .footnote)
        }
    }

    @ViewBuilder private func status(_ style: AtlasStyle?) -> some View {
        if let message = model.errorMessage {
            Text(message)
                .font(style?.smallFont ?? .footnote)
                .foregroundColor(style.map { $0.palette.color(.danger) } ?? .red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.busy {
            if let style {
                ProgressView().tint(style.palette.color(.primary)).frame(maxWidth: .infinity)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder private func heading(_ text: String, _ style: AtlasStyle?) -> some View {
        if let style {
            Text(text).font(style.headingFont).foregroundColor(style.palette.color(.text))
        } else {
            #if os(watchOS)
            Text(text).font(.headline)
            #else
            Text(text).font(.title2).bold()
            #endif
        }
    }

    @ViewBuilder private func caption(_ text: String, _ style: AtlasStyle?) -> some View {
        if let style {
            Text(text).font(style.smallFont).foregroundColor(style.palette.color(.muted))
        } else {
            #if os(watchOS)
            Text(text).font(.footnote).foregroundColor(.secondary)
            #else
            Text(text).font(.subheadline)
            #endif
        }
    }

    @ViewBuilder private func field(_ title: String, text: Binding<String>, _ style: AtlasStyle?) -> some View {
        if let style {
            TextField(title, text: text)
                .modifier(AtlasInputModifier(style: style))
                .modifier(AtlasIdentifierInput())
        } else {
            TextField(title, text: text)
                .modifier(AtlasPlatformFieldStyle())
                .modifier(AtlasIdentifierInput())
        }
    }

    @ViewBuilder private func secureField(_ title: String, text: Binding<String>, _ style: AtlasStyle?) -> some View {
        if let style {
            SecureField(title, text: text).modifier(AtlasInputModifier(style: style))
        } else {
            SecureField(title, text: text).modifier(AtlasPlatformFieldStyle())
        }
    }

    @ViewBuilder private func primaryButton(
        _ title: String, _ style: AtlasStyle?, enabled: Bool = true, _ action: @escaping () -> Void
    ) -> some View {
        if let style {
            Button(title, action: action)
                .buttonStyle(AtlasPrimaryButtonStyle(style: style))
                .disabled(model.busy || !enabled)
        } else {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !enabled)
        }
    }

    @ViewBuilder private func secondaryButton(
        _ title: String, _ style: AtlasStyle?, _ action: @escaping () -> Void
    ) -> some View {
        if let style {
            Button(title, action: action)
                .buttonStyle(AtlasSecondaryButtonStyle(style: style))
                .disabled(model.busy)
        } else {
            #if os(tvOS) || os(watchOS)
            Button(title, action: action).buttonStyle(.bordered).disabled(model.busy)
            #else
            Button(title, action: action).disabled(model.busy)
            #endif
        }
    }
}
#endif
