import Foundation

/// A sign-in attempt (§5). The SDK never advances the flow itself — it reads
/// `status` and lets the server say what the next step is. Mirrors the FAPI
/// `sign_in_attempt` / `AttemptView` shape.
public struct SignInAttempt: Decodable, Sendable, Equatable {
    public let id: String
    public let status: String
    /// The server's list of first-factor strategies. §13.2 makes this identical
    /// for unknown identifiers, so it must never be filtered client-side.
    public let supportedFirstFactors: [String]?
    public let createdSessionId: String?
    /// Present only when a redirect flow returns an authorize URL.
    public let authorizationURL: String?
    /// Present for exactly one step — the one that reached `complete`. Exchanged
    /// for a session, then gone.
    public let ticket: String?

    enum CodingKeys: String, CodingKey {
        case id, status, ticket
        case supportedFirstFactors = "supported_first_factors"
        case createdSessionId = "created_session_id"
        case authorizationURL = "authorization_url"
    }

    public var isComplete: Bool { status == "complete" }
}

/// The response of a ticket exchange or a token rotation (§9.2). `jwt` is the
/// short-lived session token; the long-lived refresh token is delivered as an
/// HttpOnly cookie and captured separately.
public struct SessionTokens: Decodable, Sendable, Equatable {
    public let id: String?
    public let sessionId: String?
    public let jwt: String
    public let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case id, jwt
        case sessionId = "session_id"
        case expiresIn = "expires_in"
    }

    /// The session id, whichever key the endpoint used (`id` on exchange,
    /// `session_id` on rotate).
    public var resolvedSessionId: String? { id ?? sessionId }
}

/// The FAPI view of the signed-in user (`GET /v1/client/me`). `privateMetadata`
/// and `passwordHash` are absent by construction on the server (§4.1); the
/// frontend may write `unsafeMetadata` and nothing else.
public struct AtlasUser: Decodable, Sendable, Equatable {
    public let id: String
    public let firstName: String?
    public let lastName: String?
    public let username: String?
    public let imageURL: String?
    public let locale: String?
    public let publicMetadata: [String: JSONValue]?
    public let unsafeMetadata: [String: JSONValue]?
    public let mfaEnabled: Bool?
    public let hasPassword: Bool?
    public let createdAt: Int?
    public let primaryEmailId: String?
    public let emailAddresses: [EmailAddress]?
    public let externalAccounts: [ExternalAccount]?
    public let passkeys: [Passkey]?

    enum CodingKeys: String, CodingKey {
        case id, locale, passkeys
        case firstName = "first_name"
        case lastName = "last_name"
        case username
        case imageURL = "image_url"
        case publicMetadata = "public_metadata"
        case unsafeMetadata = "unsafe_metadata"
        case mfaEnabled = "mfa_enabled"
        case hasPassword = "has_password"
        case createdAt = "created_at"
        case primaryEmailId = "primary_email_id"
        case emailAddresses = "email_addresses"
        case externalAccounts = "external_accounts"
    }
}

public struct EmailAddress: Decodable, Sendable, Equatable {
    public let id: String
    public let emailAddress: String
    public let verified: Bool
    public let primary: Bool

    enum CodingKeys: String, CodingKey {
        case id, verified, primary
        case emailAddress = "email_address"
    }
}

public struct ExternalAccount: Decodable, Sendable, Equatable {
    public let id: String
    public let provider: String
    /// The provider's email is a snapshot, not authoritative for ownership
    /// (§4.2) — do not treat it as identity.
    public let providerEmail: String?
    public let connectedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, provider
        case providerEmail = "provider_email"
        case connectedAt = "connected_at"
    }
}

public struct Passkey: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String?
}

/// What the SDK persists after sign-in. The `token` (session JWT) goes in the
/// Keychain; `refreshToken` is the HttpOnly `__atlas_rt` cookie the SDK re-presents
/// on authenticated calls and rotates on refresh.
public struct AtlasSession: Codable, Sendable, Equatable {
    public let sessionId: String
    public var token: String
    public var refreshToken: String?

    public init(sessionId: String, token: String, refreshToken: String? = nil) {
        self.sessionId = sessionId
        self.token = token
        self.refreshToken = refreshToken
    }
}
