import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// Step-up re-authentication with a passkey or a push prompt, next to the
/// password / code strategies of ``AtlasClient/stepUp(strategy:password:code:)``.

/// What starting a push step-up returns: show ``numberMatch`` on this screen; the
/// user taps the same number on their device.
public struct StepUpPushChallenge: Decodable, Sendable, Equatable {
    public let numberMatch: String?
    enum CodingKeys: String, CodingKey { case numberMatch = "number_match" }
}

struct StepUpPasskeyOptions: Decodable, Equatable {
    let challenge: String
    let rpId: String
}

/// The `POST /me/step_up` body for a passkey assertion (no `handle`).
func stepUpPasskeyBody(challenge: String, result: PasskeyAssertionResult) -> [String: Any] {
    [
        "strategy": "passkey",
        "challenge": challenge,
        "credential_id": result.credentialID.base64URLEncodedString(),
        "authenticator_data": result.authenticatorData.base64URLEncodedString(),
        "client_data_json": result.clientDataJSON.base64URLEncodedString(),
        "signature": result.signature.base64URLEncodedString(),
    ]
}

extension AtlasClient {
    /// Persist the fresh session token a step-up answers with; false when it
    /// carried none (a push still pending, 202).
    func persistStepUp(_ data: Data) throws -> Bool {
        guard let stored = try tokenStore.load(),
              let tokens = try? decode(SessionTokens.self, from: data) else { return false }
        try tokenStore.save(AtlasSession(
            sessionId: tokens.resolvedSessionId ?? stored.sessionId,
            token: tokens.jwt,
            refreshToken: stored.refreshToken
        ))
        return true
    }

    /// Send the signed-in session a push step-up prompt
    /// (`POST /v1/client/me/step_up/push`; 429 `LOCKED` while prompts are paused
    /// after denials). Then call ``stepUpPush()`` until it returns true.
    public func beginPushStepUp() async throws -> StepUpPushChallenge {
        try await authedDecode(StepUpPushChallenge.self, "POST", "/v1/client/me/step_up/push", json: [:])
    }

    /// Ask whether the user answered the push prompt: true once they approved
    /// (the fresh token is persisted), false while it is still pending.
    public func stepUpPush() async throws -> Bool {
        let (data, _) = try await authedSend("POST", "/v1/client/me/step_up", json: ["strategy": "push"])
        return try persistStepUp(data)
    }

    #if canImport(AuthenticationServices) && !os(watchOS)
    /// Step up with a passkey: `POST /v1/client/me/step_up/passkey` for the
    /// challenge, the system passkey sheet, then the assertion to
    /// `POST /v1/client/me/step_up`. The fresh session token is persisted.
    @available(iOS 16.0, macOS 12.0, tvOS 16.0, *)
    public func stepUpWithPasskey() async throws {
        let options = try await authedDecode(StepUpPasskeyOptions.self, "POST", "/v1/client/me/step_up/passkey", json: [:])
        guard let challenge = Data(base64URLEncoded: options.challenge) else {
            throw AtlasError.decoding("The passkey challenge was not valid base64url.")
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpId)
        let credential = try await PasskeyCeremony().perform(provider.createCredentialAssertionRequest(challenge: challenge))
        guard let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw AtlasError.decoding("The authenticator returned an unexpected credential type.")
        }
        let body = stepUpPasskeyBody(challenge: options.challenge, result: PasskeyAssertionResult(
            credentialID: assertion.credentialID,
            authenticatorData: assertion.rawAuthenticatorData,
            clientDataJSON: assertion.rawClientDataJSON,
            signature: assertion.signature
        ))
        let (data, _) = try await authedSend("POST", "/v1/client/me/step_up", json: body)
        _ = try persistStepUp(data)
    }
    #endif
}
