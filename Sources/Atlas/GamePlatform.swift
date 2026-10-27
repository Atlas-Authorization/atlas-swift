import Foundation

/// Apple Game Center sign-in. The game proves who the player is with Game Center's identity
/// verification signature; Atlas verifies it server-side (`POST /v1/oauth/game_platform`) and
/// answers like any other attempt.

/// The proof `GKLocalPlayer.fetchItems(forIdentityVerificationSignature:)` returns, in the
/// shape the server expects.
public struct GameCenterProof: Sendable, Equatable {
    public let playerId: String
    public let bundleId: String
    public let publicKeyURL: String
    public let signature: Data
    public let salt: Data
    /// Milliseconds since the epoch, as Game Center reports it.
    public let timestamp: UInt64
    public let displayName: String?

    public init(playerId: String, bundleId: String, publicKeyURL: String, signature: Data, salt: Data, timestamp: UInt64, displayName: String? = nil) {
        self.playerId = playerId
        self.bundleId = bundleId
        self.publicKeyURL = publicKeyURL
        self.signature = signature
        self.salt = salt
        self.timestamp = timestamp
        self.displayName = displayName
    }
}

/// The `POST /v1/oauth/game_platform` body for a Game Center proof. Pure; unit-tested.
public func gameCenterSignInBody(_ proof: GameCenterProof) -> [String: Any] {
    var gc: [String: Any] = [
        "player_id": proof.playerId,
        "bundle_id": proof.bundleId,
        "public_key_url": proof.publicKeyURL,
        "signature": proof.signature.base64EncodedString(),
        "salt": proof.salt.base64EncodedString(),
        "timestamp": proof.timestamp,
    ]
    if let name = proof.displayName { gc["display_name"] = name }
    return ["provider": "apple_game_center", "game_center": gc]
}

/// The body for a Google Play Games server auth code (used by cross-platform games).
public func playGamesSignInBody(serverAuthCode: String) -> [String: Any] {
    ["provider": "google_play_games", "server_auth_code": serverAuthCode]
}

extension AtlasClient {
    /// Sign in with a Game Center proof. See ``GameCenterProof`` and, on Apple platforms,
    /// ``AtlasClient/signInWithGameCenter()``.
    public func signInWithGameCenter(proof: GameCenterProof) async throws -> IdTokenSignIn {
        try await signInWithGamePlatform(body: gameCenterSignInBody(proof))
    }

    func signInWithGamePlatform(body: [String: Any]) async throws -> IdTokenSignIn {
        let (data, response) = try await sendJSON("POST", "/v1/oauth/game_platform", json: body, refreshCookie: nil)
        try throwIfError(status: response.statusCode, data: data)
        let result = try decode(IdTokenAttemptResponse.self, from: data)
        if result.status == SignInStatus.complete.rawValue, let ticket = result.ticket {
            try await exchangeTicket(attemptId: result.id, ticket: ticket)
            return .complete(try await currentUser())
        }
        let attempt = SignInAttempt(
            id: result.id,
            status: result.status,
            supportedFirstFactors: nil,
            createdSessionId: nil,
            authorizationURL: nil,
            ticket: result.ticket,
            pendingPolicies: result.pendingPolicies,
            policyAcceptanceToken: result.policyAcceptanceToken
        )
        return .needsNextStep(SignInFlow(client: self, attempt: attempt))
    }
}

#if canImport(GameKit) && !os(watchOS)
import GameKit

@available(iOS 13.5, macOS 10.15.5, tvOS 13.4.8, visionOS 1.0, *)
extension AtlasClient {
    /// Ask Game Center for the local player's identity proof and sign in with it.
    /// The player must already be authenticated with Game Center (`GKLocalPlayer.local.isAuthenticated`).
    public func signInWithGameCenter() async throws -> IdTokenSignIn {
        let player = GKLocalPlayer.local
        let proof: GameCenterProof = try await withCheckedThrowingContinuation { cont in
            player.fetchItems(forIdentityVerificationSignature: { url, signature, salt, timestamp, error in
                if let error { return cont.resume(throwing: error) }
                guard let url, let signature, let salt else {
                    return cont.resume(throwing: AtlasError.transport("Game Center returned no identity proof."))
                }
                cont.resume(returning: GameCenterProof(
                    playerId: player.teamPlayerID,
                    bundleId: Bundle.main.bundleIdentifier ?? "",
                    publicKeyURL: url.absoluteString,
                    signature: signature,
                    salt: salt,
                    timestamp: timestamp,
                    displayName: player.displayName
                ))
            })
        }
        return try await signInWithGameCenter(proof: proof)
    }
}
#endif
