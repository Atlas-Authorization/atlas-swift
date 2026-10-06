import Foundation

/// Native passkeys / WebAuthn — register for the signed-in user and sign in.
///
/// This is the Swift peer of the JS `createPasskey` / `getPasskeyAssertion`
/// helpers and `@atlasauth/expo-passkeys`. A passkey ceremony is a two-call
/// dance: the server's `begin` response describes the ceremony (challenge,
/// relying-party id, user), the platform authenticator performs it, and the
/// result is POSTed to `finish`.
///
///   register: POST /v1/client/me/passkeys/begin → create → /finish
///   sign in : POST /v1/client/sign_ins/passkey/begin → get → /finish
///
/// The relying-party id and challenge are taken FROM THE BEGIN RESPONSE — never
/// hardcoded. The rpId the server returns is the instance's Frontend API host,
/// which is exactly the host Atlas serves the matching
/// `/.well-known/apple-app-site-association` on, so the app's
/// `webcredentials:<host>` Associated-Domains entitlement lines up with it.
///
/// The pure body-mapping (platform credential → `finish` body) is split out and
/// unit-tested without a device; only the ``ASAuthorizationController`` ceremony
/// is Apple- and OS-version-gated.

// MARK: - base64url

extension Data {
    /// base64url, no padding — the encoding every WebAuthn binary field uses.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string (padded or not) into bytes.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s)
    }
}

// MARK: - begin responses

/// The WebAuthn creation options a passkey-register `begin` returns. Mirrors the
/// server's §5.5 shape; fields the ceremony does not need are ignored.
struct PasskeyRegistrationOptions: Decodable, Equatable {
    struct RelyingParty: Decodable, Equatable {
        /// The rpId — the instance's Frontend API host. Drives the ASAuthorization
        /// provider and must match the app's `webcredentials:` entitlement.
        let id: String
        let name: String?
    }

    struct UserEntity: Decodable, Equatable {
        /// The user handle, base64url. Stored on the authenticator — never the email.
        let id: String
        /// The account name shown in the OS passkey prompt.
        let name: String
        let displayName: String?
    }

    /// The server-issued challenge, base64url. Echoed verbatim to `finish`.
    let challenge: String
    let rp: RelyingParty
    let user: UserEntity
}

/// The WebAuthn request options a passkey-sign-in `begin` returns.
struct PasskeyAuthenticationOptions: Decodable, Equatable {
    /// Opaque server handle binding the challenge to this attempt. Echoed to `finish`.
    let handle: String
    /// The server-issued challenge, base64url. Echoed verbatim to `finish`.
    let challenge: String
    /// The rpId — the instance's Frontend API host.
    let rpId: String
}

/// What a passkey sign-in `finish` answers with: a complete session, delivered
/// as the JWT directly (plus the `__atlas_rt` refresh token in a `Set-Cookie`),
/// not a ticket to exchange.
struct PasskeySignInResponse: Decodable, Equatable {
    let jwt: String
    let createdSessionId: String?
    let expiresIn: Int?
    let clonedAuthenticatorWarning: Bool?

    enum CodingKeys: String, CodingKey {
        case jwt
        case createdSessionId = "created_session_id"
        case expiresIn = "expires_in"
        case clonedAuthenticatorWarning = "cloned_authenticator_warning"
    }
}

// MARK: - pure body mapping (unit-tested without a device)

/// The fields a platform attestation yields, independent of ASAuthorization so
/// the mapping is testable on any host.
struct PasskeyRegistrationResult: Equatable {
    let attestationObject: Data
    let clientDataJSON: Data
}

/// The fields a platform assertion yields, independent of ASAuthorization.
struct PasskeyAssertionResult: Equatable {
    let credentialID: Data
    let authenticatorData: Data
    let clientDataJSON: Data
    let signature: Data
}

/// Map a register `begin` challenge + attestation to the `/finish` body.
/// Field names are the exact server contract; the challenge is echoed as the
/// server sent it (the server matched and stored that exact string).
func registrationFinishBody(
    challenge: String,
    result: PasskeyRegistrationResult,
    name: String?
) -> [String: String] {
    var body: [String: String] = [
        "challenge": challenge,
        "attestation_object": result.attestationObject.base64URLEncodedString(),
        "client_data_json": result.clientDataJSON.base64URLEncodedString(),
    ]
    if let name, !name.isEmpty { body["name"] = name }
    return body
}

/// Map a sign-in `begin` handle/challenge + assertion to the `/finish` body.
func assertionFinishBody(
    handle: String,
    challenge: String,
    result: PasskeyAssertionResult
) -> [String: String] {
    [
        "handle": handle,
        "challenge": challenge,
        "credential_id": result.credentialID.base64URLEncodedString(),
        "authenticator_data": result.authenticatorData.base64URLEncodedString(),
        "client_data_json": result.clientDataJSON.base64URLEncodedString(),
        "signature": result.signature.base64URLEncodedString(),
    ]
}

// MARK: - ASAuthorization ceremony (Apple platforms, OS-version gated)

#if canImport(AuthenticationServices) && !os(watchOS)
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Wraps the delegate-based ``ASAuthorizationController`` in an async/await call.
///
/// A single ceremony — created, run once, and discarded. It holds the controller
/// (whose `delegate` is weak) and the continuation alive for the duration of the
/// system sheet, and resumes exactly once on completion, failure, or cancel.
@available(iOS 16.0, macOS 12.0, tvOS 16.0, *)
final class PasskeyCeremony: NSObject {
    private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?
    private var controller: ASAuthorizationController?

    /// Present the system passkey sheet for `request` and await its credential.
    /// Driven on the main actor — the sheet must be started from the main thread.
    /// Throws the platform `ASAuthorizationError` on failure or cancellation.
    @MainActor
    func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorizationCredential, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(with: result)
    }
}

@available(iOS 16.0, macOS 12.0, tvOS 16.0, *)
extension PasskeyCeremony: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization.credential))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }
}

@available(iOS 16.0, macOS 12.0, tvOS 16.0, *)
extension PasskeyCeremony: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if canImport(UIKit)
        return PasskeyCeremony.activeWindow() ?? ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

#if canImport(UIKit)
@available(iOS 16.0, tvOS 16.0, *)
extension PasskeyCeremony {
    /// Best-effort active window for the system sheet to anchor to.
    static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }
}
#endif

// MARK: - public API

extension AtlasClient {
    /// Register a passkey for the signed-in user (`POST /v1/client/me/passkeys/begin`
    /// → system ceremony → `…/finish`). The `/me/*` routes authenticate with the
    /// stored session JWT as a bearer plus the publishable key — the cookieless
    /// native path.
    ///
    /// - Parameter name: an optional label for the credential, shown in the user's
    ///   device passkey list.
    /// - Returns: the created ``Passkey``.
    /// - Throws: ``AtlasError`` on an API failure (e.g. `notSignedIn`,
    ///   `authenticator_not_allowed`, `identifier_exists`); the platform
    ///   `ASAuthorizationError` if the system ceremony fails or is cancelled.
    @available(iOS 16.0, macOS 12.0, tvOS 16.0, *)
    @discardableResult
    public func registerPasskey(name: String? = nil) async throws -> Passkey {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        let bearer = stored.token

        let (beginData, beginResponse) = try await send(
            "POST", "/v1/client/me/passkeys/begin",
            body: [:], refreshCookie: nil, authorization: bearer
        )
        try throwIfError(status: beginResponse.statusCode, data: beginData)
        let options = try decode(PasskeyRegistrationOptions.self, from: beginData)

        guard
            let challenge = Data(base64URLEncoded: options.challenge),
            let userID = Data(base64URLEncoded: options.user.id)
        else {
            throw AtlasError.decoding("The passkey registration options were not valid base64url.")
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rp.id
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: options.user.name,
            userID: userID
        )

        let credential = try await PasskeyCeremony().perform(request)
        guard let registration = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw AtlasError.decoding("The authenticator returned an unexpected credential type.")
        }

        let result = PasskeyRegistrationResult(
            attestationObject: registration.rawAttestationObject ?? Data(),
            clientDataJSON: registration.rawClientDataJSON
        )
        let body = registrationFinishBody(challenge: options.challenge, result: result, name: name)

        let (finishData, finishResponse) = try await send(
            "POST", "/v1/client/me/passkeys/finish",
            body: body, refreshCookie: nil, authorization: bearer
        )
        try throwIfError(status: finishResponse.statusCode, data: finishData)
        return try decode(Passkey.self, from: finishData)
    }

    /// Sign in with a passkey (`POST /v1/client/sign_ins/passkey/begin` → system
    /// ceremony → `…/finish`). No bearer — the publishable key alone; the
    /// credential names the user. On success the returned session JWT and the
    /// `__atlas_rt` refresh token are persisted to the ``TokenStore``, exactly as
    /// a password sign-in does, and the signed-in user is returned.
    ///
    /// - Returns: the freshly signed-in ``AtlasUser``.
    /// - Throws: ``AtlasError`` on an API failure; the platform
    ///   `ASAuthorizationError` if the system ceremony fails or is cancelled.
    @available(iOS 16.0, macOS 12.0, tvOS 16.0, *)
    @discardableResult
    public func signInWithPasskey() async throws -> AtlasUser {
        let (beginData, beginResponse) = try await send(
            "POST", "/v1/client/sign_ins/passkey/begin",
            body: [:], refreshCookie: nil
        )
        try throwIfError(status: beginResponse.statusCode, data: beginData)
        let options = try decode(PasskeyAuthenticationOptions.self, from: beginData)

        guard let challenge = Data(base64URLEncoded: options.challenge) else {
            throw AtlasError.decoding("The passkey challenge was not valid base64url.")
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rpId
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let credential = try await PasskeyCeremony().perform(request)
        guard let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw AtlasError.decoding("The authenticator returned an unexpected credential type.")
        }

        let result = PasskeyAssertionResult(
            credentialID: assertion.credentialID,
            authenticatorData: assertion.rawAuthenticatorData,
            clientDataJSON: assertion.rawClientDataJSON,
            signature: assertion.signature
        )
        let body = assertionFinishBody(handle: options.handle, challenge: options.challenge, result: result)

        let (finishData, finishResponse) = try await send(
            "POST", "/v1/client/sign_ins/passkey/finish",
            body: body, refreshCookie: nil
        )
        try throwIfError(status: finishResponse.statusCode, data: finishData)

        let session = try decode(PasskeySignInResponse.self, from: finishData)
        let refresh = extractCookie(Cookie.refresh, from: finishResponse)
        try tokenStore.save(AtlasSession(
            sessionId: session.createdSessionId ?? "",
            token: session.jwt,
            refreshToken: refresh
        ))

        return try await currentUser()
    }
}
#endif
