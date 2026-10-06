import Foundation

/// Native id_token sign-in — "Sign in with Apple" and Google One-Tap / GSI.
///
/// The app already holds a provider `id_token` (an Apple identity token, a Google
/// GSI credential) and posts it to `POST /v1/client/sign_ins/id_token` instead of
/// running the redirect flow (§6). The server verifies the token (audience-pinned,
/// `email_verified`-gated, nonce-bound when a nonce was minted) and answers like
/// any other attempt: a `complete` status carries the one-time `ticket` to
/// exchange for cookies; a `needs_second_factor` status means a factor is still
/// owed, which the ``SignInFlow`` driver resumes.
///
/// The request/response mapping (``idTokenSignInBody``) is pure and unit-tested
/// without a device; only the Apple ``ASAuthorizationController`` ceremony is
/// Apple- and OS-gated.

// MARK: - pure request mapping (unit-tested without a device)

/// Build the `POST /v1/client/sign_ins/id_token` body. The field names are the
/// exact server contract; the nonce is included only when one was minted.
public func idTokenSignInBody(provider: String, idToken: String, nonce: String?) -> [String: Any] {
    var body: [String: Any] = ["provider": provider, "id_token": idToken]
    if let nonce, !nonce.isEmpty { body["nonce"] = nonce }
    return body
}

/// Decode an Apple identity token's raw `Data` (UTF-8 JWT bytes, as
/// `ASAuthorizationAppleIDCredential.identityToken` hands them over) into the
/// string the server expects. Pure, so it is testable without the system sheet.
public func appleIdentityToken(from data: Data?) -> String? {
    guard let data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
    return token
}

/// The server's response to a native id_token sign-in.
struct IdTokenAttemptResponse: Decodable {
    let id: String
    let status: String
    let ticket: String?
}

/// The nonce a `/id_token/nonce` mint returns.
struct NativeNonceResponse: Decodable {
    let nonce: String?
}

// MARK: - outcome

/// The result of a native id_token sign-in. A `complete` sign-in yields the
/// signed-in user (the session is already persisted); a server that still owes a
/// second factor yields a ``SignInFlow`` seeded at `needs_second_factor`, which the
/// caller drives to completion exactly like a password sign-in.
public enum IdTokenSignIn: Sendable {
    case complete(AtlasUser)
    case needsNextStep(SignInFlow)
}

// MARK: - client API

extension AtlasClient {
    /// Mint a single-use nonce for a native id_token sign-in (§6). Call this first,
    /// hand the nonce to the provider SDK (Apple `request.nonce`, Google GSI
    /// `initialize({ nonce })`) so it is embedded in the token, then pass the SAME
    /// nonce to ``signInWithIdToken(provider:idToken:nonce:)``. Returns `nil` when
    /// the mint failed (e.g. the provider does not support native sign-in).
    public func mintNativeNonce(provider: String) async throws -> String? {
        let (data, response) = try await sendJSON(
            "POST", "/v1/client/sign_ins/id_token/nonce", json: ["provider": provider], refreshCookie: nil
        )
        try throwIfError(status: response.statusCode, data: data)
        return (try? decode(NativeNonceResponse.self, from: data))?.nonce
    }

    /// Exchange a provider `id_token` for an Atlas session (`POST
    /// /v1/client/sign_ins/id_token`). On a `complete` attempt the completion
    /// ticket is exchanged and the JWT + refresh cookie persisted; on a
    /// `needs_second_factor` attempt a seeded ``SignInFlow`` is returned so the
    /// caller can prompt for the code.
    ///
    /// - Parameters:
    ///   - provider: the provider key (`apple`, `google`, `facebook`, …).
    ///   - idToken: the provider-issued OIDC id_token.
    ///   - nonce: the nonce from ``mintNativeNonce(provider:)``, if one was used.
    public func signInWithIdToken(
        provider: String,
        idToken: String,
        nonce: String? = nil
    ) async throws -> IdTokenSignIn {
        let body = idTokenSignInBody(provider: provider, idToken: idToken, nonce: nonce)
        let (data, response) = try await sendJSON(
            "POST", "/v1/client/sign_ins/id_token", json: body, refreshCookie: nil
        )
        try throwIfError(status: response.statusCode, data: data)
        let result = try decode(IdTokenAttemptResponse.self, from: data)

        if result.status == SignInStatus.complete.rawValue, let ticket = result.ticket {
            try await exchangeTicket(attemptId: result.id, ticket: ticket)
            return .complete(try await currentUser())
        }

        // A factor is still owed — hand back a flow seeded at this attempt so the
        // caller drives the second factor with the same driver a password login uses.
        let attempt = SignInAttempt(
            id: result.id,
            status: result.status,
            supportedFirstFactors: nil,
            createdSessionId: nil,
            authorizationURL: nil,
            ticket: result.ticket
        )
        return .needsNextStep(SignInFlow(client: self, attempt: attempt))
    }
}

// MARK: - Sign in with Apple helper (Apple platforms, OS-version gated)

#if canImport(AuthenticationServices) && !os(watchOS) && !os(tvOS)
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// What a completed "Sign in with Apple" ceremony yields. The `identityToken` is
/// the JWT to post via ``AtlasClient/signInWithIdToken(provider:idToken:nonce:)``
/// with `provider: "apple"`. The profile fields are present only on the FIRST
/// sign-in for this Apple ID (Apple never resends them) — persist them then.
@available(iOS 13.0, macOS 10.15, *)
public struct AppleSignInResult: Sendable {
    public let identityToken: String
    public let authorizationCode: String?
    public let userIdentifier: String
    public let email: String?
    public let fullName: PersonNameComponents?
}

/// A small `async/await` wrapper over `ASAuthorizationController` for a
/// "Sign in with Apple" request. Create it, call ``signIn(nonce:)``, post the
/// returned `identityToken`. A single ceremony — run once and discarded.
@available(iOS 13.0, macOS 10.15, *)
public final class SignInWithApple: NSObject {
    private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?
    private var controller: ASAuthorizationController?

    public override init() { super.init() }

    /// Present the Apple sign-in sheet and return the credential.
    ///
    /// - Parameter nonce: pass the value from
    ///   ``AtlasClient/mintNativeNonce(provider:)`` so the token is replay-bound;
    ///   Apple expects a SHA-256 hash of the nonce in `request.nonce` when you want
    ///   the raw nonce echoed back in the token — set that yourself if required.
    @MainActor
    public func signIn(nonce: String? = nil) async throws -> AppleSignInResult {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        if let nonce { request.nonce = nonce }

        let credential = try await withCheckedThrowingContinuation { (c: CheckedContinuation<ASAuthorizationCredential, Error>) in
            self.continuation = c
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }

        guard let appleId = credential as? ASAuthorizationAppleIDCredential else {
            throw AtlasError.decoding("Apple returned an unexpected credential type.")
        }
        guard let token = appleIdentityToken(from: appleId.identityToken) else {
            throw AtlasError.decoding("Apple returned no identity token.")
        }
        return AppleSignInResult(
            identityToken: token,
            authorizationCode: appleId.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
            userIdentifier: appleId.user,
            email: appleId.email,
            fullName: appleId.fullName
        )
    }

    private func finish(_ result: Result<ASAuthorizationCredential, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(with: result)
    }
}

@available(iOS 13.0, macOS 10.15, *)
extension SignInWithApple: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization.credential))
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }
}

@available(iOS 13.0, macOS 10.15, *)
extension SignInWithApple: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first ?? ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
