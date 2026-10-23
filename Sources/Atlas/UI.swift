// The prebuilt SwiftUI screens, native on every Apple platform: iOS 15+,
// macOS 12+ and visionOS 1+ (the form), tvOS 17+ (sign in on another device,
// passkey, Sign in with Apple and the form, laid out for the focus engine) and
// watchOS 10+ (sign in on another device and Sign in with Apple first).
#if canImport(SwiftUI)
import SwiftUI
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// Prebuilt SwiftUI surfaces — the Swift peer of `@atlas/react`'s `<SignIn>` /
/// `<UserButton>` / `<UserProfile>` and `useSession`. The whole file is gated on
/// `canImport(SwiftUI)` so the non-UI core still builds on targets without it, and
/// each view is availability-gated to the SwiftUI release it is designed for.
///
/// None of this can be *visually* verified without a device/simulator; the logic
/// it drives (the flow driver, the client calls) is unit-tested headless.

// MARK: - observable session

/// The reactive session a UI binds to: the signed-in user, a loading flag, and
/// the last error. It wraps an ``AtlasClient`` and keeps `@Published` state in
/// step with the token store. `@MainActor` so every mutation lands on the main
/// thread, where SwiftUI expects it.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public final class AtlasAuthSession: ObservableObject {
    public let client: AtlasClient

    /// The signed-in user, or `nil` when signed out / not yet loaded.
    @Published public private(set) var user: AtlasUser?
    /// Whether a request is in flight.
    @Published public private(set) var isLoading = false
    /// The last error surfaced to the UI, cleared on the next successful call.
    @Published public private(set) var error: AtlasError?

    public init(client: AtlasClient) {
        self.client = client
    }

    public var isSignedIn: Bool { user != nil }

    /// Load the signed-in user if a session is persisted; a no-op (user stays
    /// `nil`) when signed out, and never throws — failures land in `error`.
    public func load() async {
        guard client.hasSession() else { user = nil; return }
        await run { self.user = try await self.client.currentUser() }
    }

    /// Password sign-in, then refresh the bound user.
    public func signIn(email: String, password: String) async {
        await run { self.user = try await self.client.signIn(email: email, password: password) }
    }

    /// Re-read the user after an out-of-band change (a completed flow, a profile edit).
    public func reload() async { await load() }

    /// Sign out and clear the bound user.
    public func signOut() async {
        await run {
            try await self.client.signOut()
            self.user = nil
        }
    }

    /// Run an async unit of work with the loading flag + error handling the UI
    /// relies on. Any ``AtlasError`` is captured; anything else is wrapped.
    private func run(_ work: @escaping () async throws -> Void) async {
        isLoading = true
        error = nil
        do {
            try await work()
        } catch let apiError as AtlasError {
            error = apiError
        } catch {
            self.error = .transport(error.localizedDescription)
        }
        isLoading = false
    }
}

// MARK: - SignIn view

/// A drop-in sign-in screen that drives the ``SignInFlow`` end to end: identifier
/// → first factor (password or email code) → second factor / MFA enrollment →
/// done. On completion it refreshes the bound ``AtlasAuthSession`` and calls
/// `onComplete`.
///
/// **Per platform.**
/// - iOS, iPadOS, macOS, visionOS: the email form (plus `onSocialSignIn` buttons).
/// - tvOS: two focus sections side by side — *sign in on another device* (a code
///   and QR code, ``AtlasDeviceSignInView``) and *sign in on this TV* (passkey,
///   Sign in with Apple when the instance enables Apple, then the email form).
/// - watchOS: *sign in on another device* first, then Sign in with Apple, with
///   the email form one tap away.
///
/// Sign in on another device needs the app's first-party OAuth client id
/// (``AtlasClient/oauthClientId``); without one the TV and watch screens open on
/// the sign-in options this device has.
///
/// **Design.** On appear it reads the instance's appearance (`GET /v1/appearance`).
/// When the app owner saved a design in the Atlas dashboard, the view renders it —
/// colours (light/dark), fonts, radii, borders, shadow, density, button / input /
/// social-button styles and the logo — at the platform's scale. Pass `appearance`
/// to override any token in code (code wins over the dashboard). With no dashboard
/// design and no `appearance`, the view keeps its plain system styling.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct SignIn: View {
    @StateObject private var model: SignInModel
    @StateObject private var device: DeviceSignInModel
    @Environment(\.colorScheme) private var systemScheme
    private let onComplete: () -> Void
    private let appearance: AtlasAppearance?
    private let onSocialSignIn: ((String) -> Void)?
    #if os(watchOS)
    /// The email form is the watch's secondary option, opened on request.
    @State private var showsEmailForm = false
    #endif

    /// - Parameters:
    ///   - session: the session to refresh when sign-in completes.
    ///   - appearance: code-level design overrides (win over the dashboard design).
    ///   - appearanceInfo: a pre-fetched ``AtlasAppearanceInfo``; when nil the view
    ///     fetches it itself (a failed fetch just keeps the default look).
    ///   - onSocialSignIn: when set, the enabled social providers are shown and the
    ///     tapped provider id is passed here (start OAuth with
    ///     ``AtlasClient/oauthAuthorizeURL(provider:redirectURI:)``).
    ///   - resuming: a flow that stopped elsewhere, to continue here: the one
    ///     ``AtlasClient/completeRedirect(_:)`` returns after a social sign-in that
    ///     still owes a policy or a second factor, or the one a passkey sign-in
    ///     hands back in ``AtlasPolicyAcceptanceNeeded``.
    ///   - onComplete: called after the session is established.
    public init(
        session: AtlasAuthSession,
        appearance: AtlasAppearance? = nil,
        appearanceInfo: AtlasAppearanceInfo? = nil,
        onSocialSignIn: ((String) -> Void)? = nil,
        resuming: SignInFlow? = nil,
        onComplete: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: SignInModel(session: session, appearanceInfo: appearanceInfo, resuming: resuming))
        _device = StateObject(wrappedValue: DeviceSignInModel(session: session))
        self.appearance = appearance
        self.onSocialSignIn = onSocialSignIn
        self.onComplete = onComplete
    }

    /// The design in effect (nil = the plain, pre-design look).
    private var style: AtlasStyle? {
        AtlasDesign.resolve(dashboard: model.appearanceInfo?.design, appearance: appearance)
            .map { AtlasStyle(design: $0, systemIsDark: systemScheme == .dark) }
    }

    public var body: some View {
        platformBody
            .onChange(of: model.completed) { done in if done { onComplete() } }
            .onChange(of: device.completed) { done in if done { onComplete() } }
            .task { await model.loadAppearance() }
            .task { await model.resume() }
    }

    @ViewBuilder private var platformBody: some View {
        #if os(tvOS)
        tvBody
        #elseif os(watchOS)
        watchBody
        #else
        standardBody
        #endif
    }

    // MARK: iOS / macOS / visionOS

    @ViewBuilder private var standardBody: some View {
        if let style {
            VStack(alignment: .leading, spacing: style.gap) {
                logo(style)
                content(style)
            }
            .foregroundColor(style.palette.color(.text))
            .modifier(AtlasCardModifier(style: style, systemIsDark: systemScheme == .dark))
        } else {
            VStack(alignment: .leading, spacing: 16) { content(nil) }
                .padding()
        }
    }

    @ViewBuilder private func content(_ style: AtlasStyle?) -> some View {
        title("Sign in", style)
        stepContent(style)
        status(style)
    }

    // MARK: tvOS

    #if os(tvOS)
    @ViewBuilder private var tvBody: some View {
        if let style {
            tvColumns(style)
                .foregroundColor(style.palette.color(.text))
                .modifier(AtlasCardModifier(style: style, systemIsDark: systemScheme == .dark))
        } else {
            tvColumns(nil)
                .padding(60)
        }
    }

    /// Sign in on another device | sign in on this TV, each its own focus section
    /// so a swipe left/right moves between them and up/down stays inside one.
    @ViewBuilder private func tvColumns(_ style: AtlasStyle?) -> some View {
        VStack(alignment: .leading, spacing: style?.gap ?? 40) {
            logo(style)
            title("Sign in", style)
            HStack(alignment: .top, spacing: 80) {
                if device.isAvailable {
                    AtlasDeviceCodePanel(model: device, style: style)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                    Divider()
                }
                VStack(alignment: .leading, spacing: style?.gap ?? 28) {
                    if device.isAvailable { caption("Or sign in on this TV", style) }
                    if case .collectIdentifier = model.step {
                        passkeyButton(style)
                        appleButton(style)
                    }
                    stepContent(style)
                    status(style)
                }
                .frame(maxWidth: device.isAvailable ? 720 : 900, alignment: .leading)
                .focusSection()
            }
        }
        .task(id: device.attempt) { await device.run() }
        .task { await model.prepareAppleSignIn() }
    }
    #endif

    // MARK: watchOS

    #if os(watchOS)
    @ViewBuilder private var watchBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style?.gap ?? 10) {
                logo(style)
                title("Sign in", style)
                if device.isAvailable {
                    AtlasDeviceCodePanel(model: device, style: style)
                }
                if case .collectIdentifier = model.step {
                    appleButton(style)
                }
                if showsEmailForm || !hasPrimaryWatchOption {
                    stepContent(style)
                } else {
                    secondaryButton("Use email", style) { showsEmailForm = true }
                }
                status(style)
            }
            .foregroundColor(style.map { $0.palette.color(.text) })
        }
        .task(id: device.attempt) { await device.run() }
        .task { await model.prepareAppleSignIn() }
    }

    /// Whether the watch has a lead option (another device, or Apple) above the form.
    private var hasPrimaryWatchOption: Bool {
        device.isAvailable || model.appleEnabled
    }
    #endif

    // MARK: on-device sign-in options (tvOS, watchOS)

    #if os(tvOS)
    /// Passkey sign-in on the TV: the system sheet offers a passkey from a nearby
    /// iPhone or iPad (or a QR code to scan) — no typing.
    @ViewBuilder private func passkeyButton(_ style: AtlasStyle?) -> some View {
        secondaryButton("Sign in with a passkey", style, systemImage: "person.badge.key.fill") {
            await model.signInWithPasskey()
        }
    }
    #endif

    #if os(tvOS) || os(watchOS)
    /// The system Sign in with Apple button, shown when the instance enables Apple.
    @ViewBuilder private func appleButton(_ style: AtlasStyle?) -> some View {
        if model.appleEnabled {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
                if let nonce = model.appleNonce { request.nonce = nonce }
            } onCompletion: { result in
                Task { await model.completeAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(systemScheme == .dark ? .white : .black)
            .frame(height: style?.controlHeight ?? AtlasPlatformMetrics.appleButtonHeight)
            .disabled(model.busy)
        }
    }
    #endif

    // MARK: shared pieces

    @ViewBuilder private func logo(_ style: AtlasStyle?) -> some View {
        if let style, let logo = style.design.logo(systemIsDark: systemScheme == .dark) {
            AsyncImage(url: logo) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(height: style.logoHeight)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
    }

    /// The step the flow is on: the identifier, factors, MFA and terminal states.
    @ViewBuilder private func stepContent(_ style: AtlasStyle?) -> some View {
        switch model.step {
        case .collectIdentifier:
            if let onSocialSignIn, let providers = model.appearanceInfo?.providers, !providers.isEmpty {
                AtlasSocialButtons(providers: providers, design: style?.design ?? .defaults, onSelect: onSocialSignIn)
            }
            field("Email", text: $model.identifier, style)
            continueButton("Continue", style) { await model.start() }

        case let .collectFirstFactor(strategies):
            if strategies.contains("password") {
                secureField("Password", text: $model.password, style)
                continueButton("Sign in", style) { await model.submitPassword() }
            }
            // Hidden once the server said the app can't send email.
            if strategies.contains("email_code") && !model.emailUnavailable {
                secondaryButton("Email me a code", style) { await model.sendEmailCode() }
            }

        case .collectEmailCode, .collectPhoneCode:
            field("Verification code", text: $model.code, style)
            continueButton("Verify", style) { await model.submitCode() }

        case .collectSecondFactor:
            caption("Enter your two-factor code", style)
            field("Authenticator / SMS / backup code", text: $model.code, style)
            continueButton("Verify", style) { await model.submitSecondFactor() }

        case .enrollSecondFactor:
            enrollmentSection(style)

        case .collectNewPassword:
            secureField("New password", text: $model.password, style)
            continueButton("Set password", style) { await model.submitPassword() }

        case .acceptPolicies:
            AtlasPolicyAcceptStep(
                policy: model.policy,
                style: style,
                busy: model.busy,
                onAccept: { acceptances in Task { await model.acceptPolicies(acceptances) } },
                onDecline: { model.declinePolicies() }
            )

        case .awaitOAuth, .collectCaptcha:
            caption("Continue in your browser to finish signing in.", style)

        case .done:
            caption("You're signed in.", style)

        case let .restart(reason):
            caption("This sign-in was \(reason). Start again.", style)
            secondaryButton("Start over", style) { model.reset() }

        case let .unknown(status):
            caption("This sign-in needs an app update (\(status)).", style)
        }
    }

    /// The last error and the in-flight indicator.
    @ViewBuilder private func status(_ style: AtlasStyle?) -> some View {
        if let message = model.errorMessage {
            if let style {
                Text(message)
                    .font(style.smallFont)
                    .foregroundColor(style.palette.color(.danger))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(message).font(.footnote).foregroundColor(.red)
            }
        }
        if model.busy {
            if let style {
                ProgressView().tint(style.palette.color(.primary)).frame(maxWidth: .infinity)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder private func enrollmentSection(_ style: AtlasStyle?) -> some View {
        if let enrollment = model.enrollment {
            #if os(tvOS) || os(watchOS)
            // Nothing to copy on a TV or a watch: the authenticator on the phone scans it.
            caption("Scan this with the authenticator app on your phone, then enter a code.", style)
            AtlasQRCodeView(text: enrollment.uri)
                .frame(maxWidth: AtlasPlatformMetrics.enrollmentQRSize, maxHeight: AtlasPlatformMetrics.enrollmentQRSize)
            #else
            caption("Scan this in your authenticator, then enter a code.", style)
            Text(enrollment.uri).font(style?.smallFont ?? .caption).textSelection(.enabled)
            #endif
            field("Authenticator code", text: $model.code, style)
            continueButton("Enable two-factor", style) { await model.confirmEnrollment() }
        } else {
            continueButton("Set up two-factor", style) { await model.beginEnrollment() }
        }
    }

    @ViewBuilder private func title(_ text: String, _ style: AtlasStyle?) -> some View {
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

    @ViewBuilder private func continueButton(
        _ title: String, _ style: AtlasStyle?, _ action: @escaping () async -> Void
    ) -> some View {
        if let style {
            Button(title) { Task { await action() } }
                .buttonStyle(AtlasPrimaryButtonStyle(style: style))
                .disabled(model.busy)
        } else {
            Button(title) { Task { await action() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
        }
    }

    @ViewBuilder private func secondaryButton(
        _ title: String, _ style: AtlasStyle?, systemImage: String? = nil, _ action: @escaping () async -> Void
    ) -> some View {
        if let style {
            Button { Task { await action() } } label: { buttonLabel(title, systemImage) }
                .buttonStyle(AtlasSecondaryButtonStyle(style: style))
                .disabled(model.busy)
        } else {
            #if os(tvOS) || os(watchOS)
            // On TV and watch a secondary action is still a full, focusable button.
            Button { Task { await action() } } label: { buttonLabel(title, systemImage) }
                .buttonStyle(.bordered)
                .disabled(model.busy)
            #else
            Button(title) { Task { await action() } }
            #endif
        }
    }

    @ViewBuilder private func buttonLabel(_ title: String, _ systemImage: String?) -> some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

/// Sizes the platform-specific layouts share.
enum AtlasPlatformMetrics {
    /// The Sign in with Apple button's height without a design (HIG minimums).
    static var appleButtonHeight: Double {
        #if os(tvOS)
        return 86
        #else
        return 44
        #endif
    }

    /// The TOTP enrollment QR code's size on screens that show it as a QR code.
    static var enrollmentQRSize: Double {
        #if os(tvOS)
        return 360
        #else
        return 150
        #endif
    }
}

/// The platform's own text-field look for the undesigned form: the rounded border
/// on iOS, macOS and visionOS; the system field on tvOS (the focus engine's lifted
/// field) and watchOS (the tap-to-type capsule), the native styles those
/// platforms define.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasPlatformFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS) || os(watchOS)
        content.textFieldStyle(.automatic)
        #else
        content.textFieldStyle(.roundedBorder)
        #endif
    }
}

/// Input traits for identifiers and codes: no autocorrect or auto-capitalisation
/// on the platforms that have a software keyboard.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasIdentifierInput: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        content
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
        #else
        content
        #endif
    }
}

/// The view-model behind ``SignIn``: it owns the ``SignInFlow`` and republishes
/// its step + errors as `@Published` state the view renders. `@MainActor` so the
/// published mutations are main-thread.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class SignInModel: ObservableObject {
    @Published var step: SignInStep = .collectIdentifier
    @Published var identifier = ""
    @Published var password = ""
    @Published var code = ""
    @Published var busy = false
    @Published var errorMessage: String?
    /// The typed code of the last error, when the SDK knows it.
    @Published var errorCode: AtlasErrorCode?
    /// Set once the server refused to send email (`EMAIL_DELIVERY_NOT_CONFIGURED`),
    /// so the UI stops offering email-based steps.
    @Published var emailUnavailable = false
    @Published var completed = false
    @Published var enrollment: MfaEnrollment?
    /// The instance appearance (dashboard design + providers), once loaded.
    @Published var appearanceInfo: AtlasAppearanceInfo?
    /// The single-use nonce the next Sign in with Apple request carries.
    @Published var appleNonce: String?

    /// The policies a held sign-in asks the user to accept.
    let policy = PolicyAcceptanceModel()

    private let session: AtlasAuthSession
    private var flow: SignInFlow
    private var appearanceRequested = false
    private var pendingResume: SignInFlow?

    init(session: AtlasAuthSession, appearanceInfo: AtlasAppearanceInfo? = nil, resuming: SignInFlow? = nil) {
        self.session = session
        self.flow = resuming ?? session.client.signInFlow()
        self.pendingResume = resuming
        self.appearanceInfo = appearanceInfo
        self.appearanceRequested = appearanceInfo != nil
    }

    /// Continue a flow handed in at creation (see ``SignIn``'s `resuming`).
    func resume() async {
        guard let resumed = pendingResume else { return }
        pendingResume = nil
        await publish(await resumed.step)
    }

    /// Show `next`; for a held sign-in, load the policies it asks for.
    private func publish(_ next: SignInStep) async {
        step = next
        if case let .acceptPolicies(pending) = next {
            policy.reset()
            do {
                policy.load(try await session.client.policies(resolving: pending))
            } catch {
                present(error)
                policy.load([])
            }
        }
    }

    /// Send the acceptances for the held sign-in and continue.
    func acceptPolicies(_ acceptances: [PolicyAcceptance]) async {
        await drive { try await self.flow.acceptPolicies(acceptances) }
        if errorCode == .policyAcceptanceRequired, case let .acceptPolicies(pending) = step {
            // A newer version was published while the screen was open: show it.
            if let fresh = try? await session.client.policies(resolving: pending) { policy.load(fresh) }
        }
    }

    /// The user declined: abandon this attempt and start over.
    func declinePolicies() {
        let title = policy.state.policies.first?.title ?? "required policies"
        reset()
        errorMessage = PolicyText.declined(title)
    }

    /// Whether the instance enables Sign in with Apple.
    var appleEnabled: Bool { appearanceInfo?.providers.contains("apple") ?? false }

    /// Fetch the appearance once. A failure is not an error the user sees: the
    /// form simply keeps its default look.
    func loadAppearance() async {
        guard !appearanceRequested else { return }
        appearanceRequested = true
        if let info = try? await session.client.appearance() { appearanceInfo = info }
    }

    func reset() {
        flow = session.client.signInFlow()
        step = .collectIdentifier
        password = ""; code = ""; errorMessage = nil; errorCode = nil; completed = false; enrollment = nil
        policy.reset()
    }

    func start() async { await drive { try await self.flow.start(identifier: self.identifier) } }
    func submitPassword() async { await drive { try await self.flow.attemptPassword(self.password) } }
    func sendEmailCode() async { await drive { try await self.flow.prepareEmailCode() } }
    func submitCode() async { await drive { try await self.flow.attemptEmailCode(self.code) } }
    func submitSecondFactor() async { await drive { try await self.flow.attemptSecondFactor(code: self.code) } }

    func beginEnrollment() async {
        await driveVoid {
            self.enrollment = try await self.flow.prepareMfaEnrollment()
            await self.publish(await self.flow.step)
        }
    }

    func confirmEnrollment() async {
        guard let enrollment else { return }
        await drive { try await self.flow.attemptMfaEnrollment(factorId: enrollment.factorId, codes: [self.code]) }
    }

    /// Mint the nonce for the next Sign in with Apple request (once the
    /// appearance says Apple is enabled). A failed mint leaves it nil; the
    /// sign-in then goes ahead unbound, as the server allows.
    func prepareAppleSignIn() async {
        await loadAppearance()
        guard appleEnabled, appleNonce == nil else { return }
        appleNonce = (try? await session.client.mintNativeNonce(provider: "apple")) ?? nil
    }

    #if canImport(AuthenticationServices)
    /// Finish a Sign in with Apple ceremony: post the identity token, then either
    /// complete or continue to the second factor the server asks for.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        let nonce = appleNonce
        appleNonce = nil // single-use
        defer { Task { await self.prepareAppleSignIn() } }
        switch result {
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            present(error)
        case let .success(authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let token = appleIdentityToken(from: credential.identityToken)
            else {
                present(AtlasError.decoding("Apple returned no identity token."))
                return
            }
            await completeIdToken(provider: "apple", idToken: token, nonce: nonce)
        }
    }
    #endif

    /// Post a provider id_token and follow the outcome.
    func completeIdToken(provider: String, idToken: String, nonce: String?) async {
        await driveVoid {
            switch try await self.session.client.signInWithIdToken(provider: provider, idToken: idToken, nonce: nonce) {
            case .complete:
                await self.finishSignedIn()
            case let .needsNextStep(next):
                self.flow = next
                await self.publish(await next.step)
            }
        }
    }

    #if canImport(AuthenticationServices) && !os(watchOS)
    /// Sign in with a passkey (the system sheet). Cancelling the sheet is not an error.
    @available(iOS 16.0, macOS 12.0, tvOS 17.0, *)
    func signInWithPasskey() async {
        await driveVoid {
            do {
                _ = try await self.session.client.signInWithPasskey()
                await self.finishSignedIn()
            } catch let error as ASAuthorizationError where error.code == .canceled {
                return
            } catch let held as AtlasPolicyAcceptanceNeeded {
                // The passkey checked out; the server wants a policy accepted first.
                self.flow = held.flow
                await self.publish(await held.flow.step)
            }
        }
    }
    #endif

    private func finishSignedIn() async {
        step = .done(sessionId: nil)
        completed = true
        await session.reload()
    }

    /// Publish an error: the server's own message verbatim (it is written for end
    /// users), plus its typed code.
    func present(_ error: Error) {
        if let error = error as? AtlasError {
            errorMessage = error.message
            errorCode = error.knownCode
            if error.isEmailDeliveryNotConfigured { emailUnavailable = true }
        } else {
            errorMessage = error.localizedDescription
            errorCode = nil
        }
    }

    /// Run a flow step that returns the next ``SignInStep``, publishing it and
    /// completion.
    private func drive(_ work: @escaping () async throws -> SignInStep) async {
        busy = true; errorMessage = nil; errorCode = nil
        do {
            let next = try await work()
            await publish(next)
            if case .done = next { completed = true; await session.reload() }
        } catch {
            present(error)
        }
        busy = false
    }

    private func driveVoid(_ work: @escaping () async throws -> Void) async {
        busy = true; errorMessage = nil; errorCode = nil
        do { try await work() } catch { present(error) }
        busy = false
    }
}

// MARK: - UserButton / UserProfile

/// A compact signed-in-user control: avatar + name with a sign-out action — the
/// `<UserButton>` equivalent. Renders nothing when signed out.
///
/// A pull-down menu on iOS, macOS, visionOS and tvOS; on watchOS (which has no
/// menus) the row opens the system confirmation sheet with the sign-out action.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct UserButton: View {
    @ObservedObject private var session: AtlasAuthSession
    #if os(watchOS)
    @State private var confirmingSignOut = false
    #endif

    public init(session: AtlasAuthSession) {
        _session = ObservedObject(wrappedValue: session)
    }

    public var body: some View {
        if let user = session.user {
            #if os(watchOS)
            Button { confirmingSignOut = true } label: { accountLabel(user) }
                .confirmationDialog(displayName(user), isPresented: $confirmingSignOut, titleVisibility: .visible) {
                    Button("Sign out", role: .destructive) { Task { await session.signOut() } }
                }
            #else
            Menu {
                Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            } label: {
                accountLabel(user)
            }
            #endif
        }
    }

    @ViewBuilder private func accountLabel(_ user: AtlasUser) -> some View {
        HStack(spacing: 8) {
            avatar(user)
            Text(displayName(user)).lineLimit(1)
        }
    }

    /// The avatar's diameter: tvOS controls are read from the sofa.
    private var avatarSize: Double {
        #if os(tvOS)
        return 56
        #else
        return 28
        #endif
    }

    @ViewBuilder private func avatar(_ user: AtlasUser) -> some View {
        if let raw = user.imageURL, let url = URL(string: raw) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.3))
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
        } else {
            Circle().fill(Color.secondary.opacity(0.3)).frame(width: avatarSize, height: avatarSize)
        }
    }

    private func displayName(_ user: AtlasUser) -> String {
        [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
            .nonEmpty ?? user.username ?? "Account"
    }
}

/// A read-oriented account screen: identity, email addresses, and a sign-out
/// button — the `<UserProfile>` equivalent. A starting point to extend with the
/// `/me` mutation methods.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct UserProfile: View {
    @ObservedObject private var session: AtlasAuthSession

    public init(session: AtlasAuthSession) {
        _session = ObservedObject(wrappedValue: session)
    }

    public var body: some View {
        if let user = session.user {
            #if os(watchOS)
            ScrollView { details(user) }
            #else
            details(user).padding()
            #endif
        } else {
            Text("Not signed in.").padding()
        }
    }

    @ViewBuilder private func details(_ user: AtlasUser) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text([user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ").nonEmpty
                 ?? user.username ?? "Account")
                .font(.title3).bold()

            if let emails = user.emailAddresses, !emails.isEmpty {
                Text("Email addresses").font(.headline)
                ForEach(emails, id: \.id) { email in
                    HStack {
                        Text(email.emailAddress)
                        if email.primary { Text("primary").font(.caption).foregroundColor(.secondary) }
                        if email.verified { Image(systemName: "checkmark.seal.fill").foregroundColor(.green) }
                    }
                }
            }

            Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            if let error = session.error {
                Text(error.message).font(.footnote).foregroundColor(.red)
            }
        }
    }
}

private extension String {
    /// Self, unless empty/whitespace, in which case nil — for name fallbacks.
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespaces).isEmpty ? nil : self
    }
}
#endif
