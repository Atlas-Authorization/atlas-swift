#if canImport(SwiftUI)
import SwiftUI

/// Prebuilt SwiftUI surfaces — the Swift peer of `@atlas/react`'s `<SignIn>` /
/// `<UserButton>` / `<UserProfile>` and `useSession`. The whole file is gated on
/// `canImport(SwiftUI)` so the non-UI core still builds on targets without it, and
/// each view is availability-gated to modern SwiftUI.
///
/// None of this can be *visually* verified without a device/simulator; the logic
/// it drives (the flow driver, the client calls) is unit-tested headless.

// MARK: - observable session

/// The reactive session a UI binds to: the signed-in user, a loading flag, and
/// the last error. It wraps an ``AtlasClient`` and keeps `@Published` state in
/// step with the token store. `@MainActor` so every mutation lands on the main
/// thread, where SwiftUI expects it.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
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
/// `onComplete`. Styling is intentionally plain — a starting point to theme.
@available(iOS 15.0, macOS 12.0, *)
public struct SignIn: View {
    @StateObject private var model: SignInModel
    private let onComplete: () -> Void

    /// - Parameters:
    ///   - session: the session to refresh when sign-in completes.
    ///   - onComplete: called after the session is established.
    public init(session: AtlasAuthSession, onComplete: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: SignInModel(session: session))
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in").font(.title2).bold()

            switch model.step {
            case .collectIdentifier:
                field("Email", text: $model.identifier)
                continueButton("Continue") { await model.start() }

            case let .collectFirstFactor(strategies):
                if strategies.contains("password") {
                    secureField("Password", text: $model.password)
                    continueButton("Sign in") { await model.submitPassword() }
                }
                if strategies.contains("email_code") {
                    Button("Email me a code") { Task { await model.sendEmailCode() } }
                }

            case .collectEmailCode, .collectPhoneCode:
                field("Verification code", text: $model.code)
                continueButton("Verify") { await model.submitCode() }

            case .collectSecondFactor:
                Text("Enter your two-factor code").font(.subheadline)
                field("Authenticator / SMS / backup code", text: $model.code)
                continueButton("Verify") { await model.submitSecondFactor() }

            case .enrollSecondFactor:
                enrollmentSection

            case .collectNewPassword:
                secureField("New password", text: $model.password)
                continueButton("Set password") { await model.submitPassword() }

            case .awaitOAuth, .collectCaptcha:
                Text("Continue in your browser to finish signing in.").font(.subheadline)

            case .done:
                Text("You're signed in.").font(.subheadline)

            case let .restart(reason):
                Text("This sign-in was \(reason). Start again.").font(.subheadline)
                Button("Start over") { model.reset() }

            case let .unknown(status):
                Text("This sign-in needs an app update (\(status)).").font(.subheadline)
            }

            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundColor(.red)
            }
            if model.busy { ProgressView() }
        }
        .padding()
        .onChange(of: model.completed) { done in if done { onComplete() } }
    }

    @ViewBuilder private var enrollmentSection: some View {
        if let enrollment = model.enrollment {
            Text("Scan this in your authenticator, then enter a code.").font(.subheadline)
            Text(enrollment.uri).font(.caption).textSelection(.enabled)
            field("Authenticator code", text: $model.code)
            continueButton("Enable two-factor") { await model.confirmEnrollment() }
        } else {
            continueButton("Set up two-factor") { await model.beginEnrollment() }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            #endif
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text).textFieldStyle(.roundedBorder)
    }

    private func continueButton(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
    }
}

/// The view-model behind ``SignIn``: it owns the ``SignInFlow`` and republishes
/// its step + errors as `@Published` state the view renders. `@MainActor` so the
/// published mutations are main-thread.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class SignInModel: ObservableObject {
    @Published var step: SignInStep = .collectIdentifier
    @Published var identifier = ""
    @Published var password = ""
    @Published var code = ""
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var completed = false
    @Published var enrollment: MfaEnrollment?

    private let session: AtlasAuthSession
    private var flow: SignInFlow

    init(session: AtlasAuthSession) {
        self.session = session
        self.flow = session.client.signInFlow()
    }

    func reset() {
        flow = session.client.signInFlow()
        step = .collectIdentifier
        password = ""; code = ""; errorMessage = nil; completed = false; enrollment = nil
    }

    func start() async { await drive { try await self.flow.start(identifier: self.identifier) } }
    func submitPassword() async { await drive { try await self.flow.attemptPassword(self.password) } }
    func sendEmailCode() async { await drive { try await self.flow.prepareEmailCode() } }
    func submitCode() async { await drive { try await self.flow.attemptEmailCode(self.code) } }
    func submitSecondFactor() async { await drive { try await self.flow.attemptSecondFactor(code: self.code) } }

    func beginEnrollment() async {
        await driveVoid {
            self.enrollment = try await self.flow.prepareMfaEnrollment()
            self.step = await self.flow.step
        }
    }

    func confirmEnrollment() async {
        guard let enrollment else { return }
        await drive { try await self.flow.attemptMfaEnrollment(factorId: enrollment.factorId, codes: [self.code]) }
    }

    /// Run a flow step that returns the next ``SignInStep``, publishing it and
    /// completion.
    private func drive(_ work: @escaping () async throws -> SignInStep) async {
        busy = true; errorMessage = nil
        do {
            let next = try await work()
            step = next
            if case .done = next { completed = true; await session.reload() }
        } catch let error as AtlasError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }

    private func driveVoid(_ work: @escaping () async throws -> Void) async {
        busy = true; errorMessage = nil
        do { try await work() }
        catch let error as AtlasError { errorMessage = error.message }
        catch { errorMessage = error.localizedDescription }
        busy = false
    }
}

// MARK: - UserButton / UserProfile

/// A compact signed-in-user control: avatar + name with a sign-out action — the
/// `<UserButton>` equivalent. Renders nothing when signed out.
@available(iOS 15.0, macOS 12.0, *)
public struct UserButton: View {
    @ObservedObject private var session: AtlasAuthSession

    public init(session: AtlasAuthSession) {
        _session = ObservedObject(wrappedValue: session)
    }

    public var body: some View {
        if let user = session.user {
            Menu {
                Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            } label: {
                HStack(spacing: 8) {
                    avatar(user)
                    Text(displayName(user)).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private func avatar(_ user: AtlasUser) -> some View {
        if let raw = user.imageURL, let url = URL(string: raw) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.3))
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else {
            Circle().fill(Color.secondary.opacity(0.3)).frame(width: 28, height: 28)
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
@available(iOS 15.0, macOS 12.0, *)
public struct UserProfile: View {
    @ObservedObject private var session: AtlasAuthSession

    public init(session: AtlasAuthSession) {
        _session = ObservedObject(wrappedValue: session)
    }

    public var body: some View {
        if let user = session.user {
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
            .padding()
        } else {
            Text("Not signed in.").padding()
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
