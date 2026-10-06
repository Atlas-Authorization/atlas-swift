import Foundation

/// The multi-step sign-in / sign-up state machine — the Swift peer of
/// `@atlas/js`'s `attempt.ts` (`nextStep`) + `fapi.ts` (`advance`).
///
/// §5: "the client reads `status` and renders whatever the server demands next;
/// it never picks the step itself." The driver holds the current attempt and
/// exposes its ``SignInStep`` so the caller drives the next action; a `complete`
/// status is turned into a real session (the completion ticket is exchanged and
/// the JWT + refresh cookie persisted through the existing ``TokenStore``), after
/// which the step is ``SignInStep/done``.
///
/// The step mapping (``signInStep(_:)``) is a pure, exhaustive function so an
/// unknown server status becomes an explicit ``SignInStep/unknown`` a UI can
/// render as "this needs an update" rather than a blank screen — the single worst
/// failure a login box has.

// MARK: - Step

/// What the UI should collect next, mirroring `@atlas/js`'s `Step`.
public enum SignInStep: Equatable, Sendable {
    case collectIdentifier
    /// The server's first-factor strategies — never a client-side guess (§13.2
    /// makes the list identical for unknown identifiers, so filtering it would
    /// reopen the enumeration leak the uniform response closes).
    case collectFirstFactor(strategies: [String])
    case collectSecondFactor
    /// §11.1 MFA policy `required` for a user with no second factor yet — distinct
    /// from ``collectSecondFactor``: there is no code to ask for, only enrollment.
    case enrollSecondFactor
    case collectEmailCode
    case collectPhoneCode
    case collectCaptcha
    case awaitOAuth
    case collectNewPassword
    /// Terminal success — the session is already persisted.
    case done(sessionId: String?)
    case restart(reason: String)
    /// A status this SDK version does not know; surface it rather than hang.
    case unknown(status: String)
}

/// The sign-in attempt statuses the server emits (§5).
public enum SignInStatus: String, Sendable {
    case needsIdentifier = "needs_identifier"
    case needsFirstFactor = "needs_first_factor"
    case needsSecondFactor = "needs_second_factor"
    case needsMfaEnrollment = "needs_mfa_enrollment"
    case needsEmailVerification = "needs_email_verification"
    case needsOAuthCallback = "needs_oauth_callback"
    case needsNewPassword = "needs_new_password"
    case needsCaptcha = "needs_captcha"
    case complete
    case abandoned
}

/// Map an attempt to the step a UI should render — the pure, device-free core of
/// the driver. An `if (status === …)` ladder silently falls through on an
/// unrecognised status; an exhaustive mapping to ``SignInStep/unknown`` does not.
public func signInStep(_ attempt: SignInAttempt) -> SignInStep {
    switch SignInStatus(rawValue: attempt.status) {
    case .needsIdentifier:
        return .collectIdentifier
    case .needsFirstFactor:
        return .collectFirstFactor(strategies: attempt.supportedFirstFactors ?? [])
    case .needsSecondFactor:
        return .collectSecondFactor
    case .needsMfaEnrollment:
        return .enrollSecondFactor
    case .needsEmailVerification:
        return .collectEmailCode
    case .needsCaptcha:
        return .collectCaptcha
    case .needsOAuthCallback:
        return .awaitOAuth
    case .needsNewPassword:
        return .collectNewPassword
    case .complete:
        return .done(sessionId: attempt.createdSessionId)
    case .abandoned:
        return .restart(reason: "abandoned")
    case .none:
        return .unknown(status: attempt.status)
    }
}

/// Whether the flow can still progress — the cue for whether to keep polling.
public func isTerminal(_ attempt: SignInAttempt) -> Bool {
    attempt.status == "complete" || attempt.status == "abandoned"
}

// MARK: - models the driver surfaces

/// The TOTP enrollment a `prepare_mfa_enrollment` returns. The `secret` is shown
/// exactly once — there is deliberately no endpoint that reveals it again.
public struct MfaEnrollment: Decodable, Sendable, Equatable {
    public let factorId: String
    public let secret: String
    /// The `otpauth://` provisioning URI, for rendering a QR code.
    public let uri: String

    enum CodingKeys: String, CodingKey {
        case factorId = "factor_id"
        case secret, uri
    }
}

/// A prepared second-factor challenge (SMS `sent_to`, push `number_match`, or a
/// passkey request). The fields present depend on the strategy; all are optional.
public struct SecondFactorChallenge: Decodable, Sendable, Equatable {
    public let strategy: String?
    public let sentTo: String?
    public let challengeId: String?
    public let numberMatch: String?

    enum CodingKeys: String, CodingKey {
        case strategy
        case sentTo = "sent_to"
        case challengeId = "challenge_id"
        case numberMatch = "number_match"
    }
}

// MARK: - sign-in driver

/// Drives a multi-step sign-in over `/v1/client/sign_ins/*`.
///
/// An `actor`: the attempt it holds is mutated only on a successful step, so a
/// failed step (a wrong password, a bad code) leaves the attempt intact and the
/// caller can retry — the same contract the JS `advance` keeps. Every completion
/// (a `ticket`) is exchanged for a session and persisted before the step resolves
/// to ``SignInStep/done``.
public actor SignInFlow {
    private let client: AtlasClient
    private var attempt: SignInAttempt?

    public init(client: AtlasClient) {
        self.client = client
    }

    /// Seed the flow with an attempt already returned by another entry point
    /// (e.g. an id_token sign-in that came back `needs_second_factor`).
    public init(client: AtlasClient, attempt: SignInAttempt) {
        self.client = client
        self.attempt = attempt
    }

    /// The current attempt's status, or `needs_identifier` before one is started.
    public var status: String { attempt?.status ?? SignInStatus.needsIdentifier.rawValue }

    /// The step the UI should render next.
    public var step: SignInStep {
        guard let attempt else { return .collectIdentifier }
        return signInStep(attempt)
    }

    /// The attempt id, once started — what a resumed step targets.
    public var attemptId: String? { attempt?.id }

    /// Create the attempt with the identifier (§5). Returns the next step — a
    /// password/email-code first factor, or a captcha challenge.
    @discardableResult
    public func start(identifier: String, captchaToken: String? = nil) async throws -> SignInStep {
        var body: [String: Any] = ["identifier": identifier]
        if let captchaToken { body["captcha_token"] = captchaToken }
        return try await post("/v1/client/sign_ins", body)
    }

    /// Submit the password first factor.
    @discardableResult
    public func attemptPassword(_ password: String) async throws -> SignInStep {
        try await postToAttempt("attempt_first_factor", ["strategy": "password", "password": password])
    }

    /// Ask the server to email a one-time code (`prepare_first_factor`).
    @discardableResult
    public func prepareEmailCode() async throws -> SignInStep {
        try await postToAttempt("prepare_first_factor", ["strategy": "email_code"])
    }

    /// Submit the emailed code.
    @discardableResult
    public func attemptEmailCode(_ code: String) async throws -> SignInStep {
        try await postToAttempt("attempt_first_factor", ["strategy": "email_code", "code": code])
    }

    /// Ask the server to text a one-time code (`prepare_first_factor`, phone_code).
    /// `channel` is `sms` (default), `whatsapp`, or `voice`.
    @discardableResult
    public func preparePhoneCode(channel: String? = nil) async throws -> SignInStep {
        var body: [String: Any] = ["strategy": "phone_code"]
        if let channel { body["channel"] = channel }
        return try await postToAttempt("prepare_first_factor", body)
    }

    /// Submit the texted code.
    @discardableResult
    public func attemptPhoneCode(_ code: String) async throws -> SignInStep {
        try await postToAttempt("attempt_first_factor", ["strategy": "phone_code", "code": code])
    }

    /// Prepare a second factor — `totp` needs no preparation; pass `sms` or `push`
    /// to have the server send/stage the challenge. Returns the challenge detail
    /// (masked number, number-match) when the server issues one.
    @discardableResult
    public func prepareSecondFactor(strategy: String) async throws -> SecondFactorChallenge {
        guard let id = attempt?.id else { throw AtlasError.notSignedIn }
        let (data, _) = try await authedAttemptPost(id, "prepare_second_factor", ["strategy": strategy])
        return try client.decode(SecondFactorChallenge.self, from: data)
    }

    /// Submit a second-factor **code** — a TOTP code, an SMS OTP, or a backup
    /// (recovery) code. The server decides which by what matches, so one method
    /// covers all three.
    @discardableResult
    public func attemptSecondFactor(code: String, rememberDevice: Bool = false) async throws -> SignInStep {
        var body: [String: Any] = ["code": code]
        if rememberDevice { body["remember_device"] = true }
        return try await postToAttempt("attempt_second_factor", body)
    }

    /// Begin TOTP enrollment mid-sign-in (§11.1, `needs_mfa_enrollment`). The
    /// returned ``MfaEnrollment`` carries the secret + provisioning URI (shown once).
    public func prepareMfaEnrollment() async throws -> MfaEnrollment {
        guard let id = attempt?.id else { throw AtlasError.notSignedIn }
        let (data, response) = try await client.sendJSON(
            "POST", "/v1/client/sign_ins/\(id)/prepare_mfa_enrollment", json: [:], refreshCookie: nil
        )
        try client.throwIfError(status: response.statusCode, data: data)
        return try client.decode(MfaEnrollment.self, from: data)
    }

    /// Confirm TOTP enrollment with the authenticator code(s). Completing it
    /// finishes the sign-in (and returns the backup codes via ``lastBackupCodes``).
    @discardableResult
    public func attemptMfaEnrollment(factorId: String, codes: [String]) async throws -> SignInStep {
        try await postToAttempt(
            "attempt_mfa_enrollment",
            ["factor_id": factorId, "codes": codes],
            captureBackupCodes: true
        )
    }

    /// The backup codes handed back by the most recent MFA enrollment, if any.
    public private(set) var lastBackupCodes: [String] = []

    // MARK: driver internals

    private func post(_ path: String, _ body: [String: Any]) async throws -> SignInStep {
        let (data, response) = try await client.sendJSON("POST", path, json: body, refreshCookie: nil)
        try client.throwIfError(status: response.statusCode, data: data)
        let decoded = try client.decode(SignInAttempt.self, from: data)
        return try await apply(decoded)
    }

    private func postToAttempt(
        _ action: String,
        _ body: [String: Any],
        captureBackupCodes: Bool = false
    ) async throws -> SignInStep {
        guard let id = attempt?.id else { throw AtlasError.notSignedIn }
        let (data, response) = try await client.sendJSON(
            "POST", "/v1/client/sign_ins/\(id)/\(action)", json: body, refreshCookie: nil
        )
        try client.throwIfError(status: response.statusCode, data: data)
        if captureBackupCodes {
            lastBackupCodes = (try? client.decode(BackupCodesEnvelope.self, from: data))?.backupCodes ?? []
        }
        let decoded = try client.decode(SignInAttempt.self, from: data)
        return try await apply(decoded)
    }

    private func authedAttemptPost(
        _ id: String, _ action: String, _ body: [String: Any]
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await client.sendJSON(
            "POST", "/v1/client/sign_ins/\(id)/\(action)", json: body, refreshCookie: nil
        )
        try client.throwIfError(status: response.statusCode, data: data)
        return (data, response)
    }

    /// Store the new attempt and, if it completed, exchange its ticket for a real
    /// session before resolving the step to `.done`.
    private func apply(_ decoded: SignInAttempt) async throws -> SignInStep {
        attempt = decoded
        if decoded.isComplete, let ticket = decoded.ticket {
            try await client.exchangeTicket(attemptId: decoded.id, ticket: ticket)
        }
        return signInStep(decoded)
    }
}

/// The backup codes a completed MFA enrollment returns alongside the attempt.
struct BackupCodesEnvelope: Decodable {
    let backupCodes: [String]?
    enum CodingKeys: String, CodingKey { case backupCodes = "backup_codes" }
}

// MARK: - sign-up driver

/// Drives a multi-step sign-up over `/v1/client/sign_ups/*` (§5). Statuses:
/// `needs_email_verification` → `complete` (carrying a session ticket).
public actor SignUpFlow {
    private let client: AtlasClient
    private var attempt: SignInAttempt?

    public init(client: AtlasClient) { self.client = client }

    public var status: String { attempt?.status ?? SignInStatus.needsIdentifier.rawValue }
    public var step: SignInStep {
        guard let attempt else { return .collectIdentifier }
        return signInStep(attempt)
    }
    public var attemptId: String? { attempt?.id }

    /// Start the sign-up. `fields` carries the tenant's configured extra fields;
    /// `consent` satisfies a required legal-consent gate.
    @discardableResult
    public func start(
        email: String,
        password: String,
        captchaToken: String? = nil,
        fields: [String: String]? = nil,
        consent: Bool? = nil,
        organizationId: String? = nil
    ) async throws -> SignInStep {
        var body: [String: Any] = ["email": email, "password": password]
        if let captchaToken { body["captcha_token"] = captchaToken }
        if let fields { body["fields"] = fields }
        if let consent { body["consent"] = consent }
        if let organizationId { body["organization_id"] = organizationId }
        return try await post("/v1/client/sign_ups", body)
    }

    /// Resend the verification email.
    @discardableResult
    public func prepareVerification() async throws -> SignInStep {
        guard let id = attempt?.id else { throw AtlasError.notSignedIn }
        return try await post("/v1/client/sign_ups/\(id)/prepare_verification", [:])
    }

    /// Submit the emailed verification code.
    @discardableResult
    public func attemptVerification(code: String) async throws -> SignInStep {
        guard let id = attempt?.id else { throw AtlasError.notSignedIn }
        return try await post("/v1/client/sign_ups/\(id)/attempt_verification", ["code": code])
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> SignInStep {
        let (data, response) = try await client.sendJSON("POST", path, json: body, refreshCookie: nil)
        try client.throwIfError(status: response.statusCode, data: data)
        let decoded = try client.decode(SignInAttempt.self, from: data)
        attempt = decoded
        if decoded.isComplete, let ticket = decoded.ticket {
            try await client.exchangeTicket(attemptId: decoded.id, ticket: ticket)
        }
        return signInStep(decoded)
    }
}

// MARK: - password-reset driver

/// The step a password-reset flow is on.
public enum ResetStep: Equatable, Sendable {
    case request
    case collectEmailCode
    case collectSecondFactor
    case collectNewPassword
    case done
    case unknown(status: String)
}

/// Drives the §5.4 "forgot password" flow over `/v1/client/password_resets/*` —
/// a standalone attempt, separate from sign-in: prove the inbox with an emailed
/// code, clear any second factor (a reset must NOT bypass MFA), set a new
/// password, and end up signed in (the completion ticket is exchanged).
public actor PasswordResetFlow {
    private let client: AtlasClient
    private var attempt: SignInAttempt?

    public init(client: AtlasClient) { self.client = client }

    public var status: String? { attempt?.status }

    /// The reset step the UI should render.
    public var step: ResetStep {
        guard let status = attempt?.status else { return .request }
        switch status {
        case "needs_email_verification": return .collectEmailCode
        case "needs_second_factor": return .collectSecondFactor
        case "needs_new_password": return .collectNewPassword
        case "complete": return .done
        default: return .unknown(status: status)
        }
    }

    /// Begin a reset: email the code.
    @discardableResult
    public func start(email: String, captchaToken: String? = nil) async throws -> ResetStep {
        var body: [String: Any] = ["email_address": email]
        if let captchaToken { body["captcha_token"] = captchaToken }
        return try await post("/v1/client/password_resets", body)
    }

    /// Submit the emailed verification code.
    @discardableResult
    public func attemptVerification(code: String) async throws -> ResetStep {
        try await action("attempt_verification", ["code": code])
    }

    /// Submit the second-factor code, when the account has MFA.
    @discardableResult
    public func attemptSecondFactor(code: String) async throws -> ResetStep {
        try await action("attempt_second_factor", ["code": code])
    }

    /// Set the new password; completing it signs the user in.
    @discardableResult
    public func setNewPassword(_ password: String) async throws -> ResetStep {
        try await action("set_new_password", ["password": password])
    }

    private func action(_ name: String, _ body: [String: Any]) async throws -> ResetStep {
        guard let id = attempt?.id else { throw AtlasError.notSignedIn }
        return try await post("/v1/client/password_resets/\(id)/\(name)", body)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> ResetStep {
        let (data, response) = try await client.sendJSON("POST", path, json: body, refreshCookie: nil)
        try client.throwIfError(status: response.statusCode, data: data)
        let decoded = try client.decode(SignInAttempt.self, from: data)
        attempt = decoded
        if decoded.isComplete, let ticket = decoded.ticket {
            try await client.exchangeTicket(attemptId: decoded.id, ticket: ticket)
        }
        return step
    }
}

// MARK: - AtlasClient entry points

extension AtlasClient {
    /// A fresh multi-step sign-in driver bound to this client.
    public func signInFlow() -> SignInFlow { SignInFlow(client: self) }

    /// A fresh multi-step sign-up driver bound to this client.
    public func signUpFlow() -> SignUpFlow { SignUpFlow(client: self) }

    /// A fresh password-reset driver bound to this client.
    public func passwordResetFlow() -> PasswordResetFlow { PasswordResetFlow(client: self) }
}
