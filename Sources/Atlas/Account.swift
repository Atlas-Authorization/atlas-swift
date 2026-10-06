import Foundation

/// Account self-management: organizations, session (device) listing + revoke, and
/// the `/v1/client/me` mutation surface (emails, external accounts, password,
/// profile + metadata). Every call is authenticated with the stored session the
/// way a browser presents it (session JWT + refresh cookie), through the single
/// ``AtlasClient/authedSend(_:_:json:)`` path.

// MARK: - models

/// A `{ object: "list", data: [...] }` envelope.
struct ListEnvelope<Item: Decodable>: Decodable {
    let data: [Item]
}

/// An organization (§8). `publicMetadata` is readable by the frontend;
/// `privateMetadata` is backend-only and never serialised here (§4.4).
public struct Organization: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let slug: String?
    public let imageURL: String?
    public let publicMetadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, name, slug
        case imageURL = "image_url"
        case publicMetadata = "public_metadata"
    }
}

/// The signed-in user's membership of one organization — the role they hold and
/// the organization itself.
public struct OrganizationMembership: Decodable, Sendable, Equatable {
    public let role: String
    public let organization: Organization
}

/// One of the signed-in user's active devices / sessions (§10.2).
public struct DeviceSession: Decodable, Sendable, Equatable {
    public let id: String
    public let status: String
    /// Whether this is the caller's own session.
    public let current: Bool?
    public let lastActiveAt: Int?
    public let expireAt: Int?
    public let createdAt: Int?
    public let ipAddress: String?
    /// A human label ("Chrome on macOS"), plus its parts.
    public let deviceLabel: String?
    public let browser: String?
    public let os: String?
    public let deviceType: String?
    public let location: String?

    enum CodingKeys: String, CodingKey {
        case id, status, current, location, browser, os
        case lastActiveAt = "last_active_at"
        case expireAt = "expire_at"
        case createdAt = "created_at"
        case ipAddress = "ip_address"
        case deviceLabel = "device_label"
        case deviceType = "device_type"
    }
}

/// The start of an external-account link flow (§6.6) — navigate the browser (or
/// an `ASWebAuthenticationSession`) to `authorizationURL`, and read the outcome
/// on your redirect URL.
public struct ExternalAccountConnection: Decodable, Sendable, Equatable {
    public let provider: String
    public let attemptId: String
    public let authorizationURL: String
    public let scopes: [String]

    enum CodingKeys: String, CodingKey {
        case provider, scopes
        case attemptId = "attempt_id"
        case authorizationURL = "authorization_url"
    }
}

/// The result of an email-address mutation. The server returns different subsets
/// per action (add carries everything; verify/primary/remove carry only what
/// changed), so every field but `id` is optional.
public struct EmailAddressResult: Decodable, Sendable, Equatable {
    public let id: String
    public let emailAddress: String?
    public let verified: Bool?
    public let primary: Bool?
    public let deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, verified, primary, deleted
        case emailAddress = "email_address"
    }
}

/// The session state a `touch` (active-organization switch) returns.
struct SessionTouchResponse: Decodable {
    let id: String?
    let jwt: String
    let expiresIn: Int?
    let lastActiveOrganizationId: String?

    enum CodingKeys: String, CodingKey {
        case id, jwt
        case expiresIn = "expires_in"
        case lastActiveOrganizationId = "last_active_organization_id"
    }
}

struct RevokeAllResponse: Decodable {
    let sessionsRevoked: Int?
    enum CodingKeys: String, CodingKey { case sessionsRevoked = "sessions_revoked" }
}

// MARK: - organizations

extension AtlasClient {
    /// The organizations the signed-in user belongs to, with their role in each
    /// (`GET /v1/client/me/organizations`).
    public func organizations() async throws -> [OrganizationMembership] {
        let envelope = try await authedDecode(
            ListEnvelope<OrganizationMembership>.self, "GET", "/v1/client/me/organizations"
        )
        return envelope.data
    }

    /// Create an organization (`POST /v1/client/organizations`) — succeeds only
    /// when the instance allows user-created organizations. The creator is seated
    /// as admin.
    @discardableResult
    public func createOrganization(name: String, slug: String) async throws -> Organization {
        try await authedDecode(
            Organization.self, "POST", "/v1/client/organizations",
            json: ["name": name, "slug": slug]
        )
    }

    /// Switch the active organization for the current session
    /// (`POST /v1/client/sessions/:id/touch`). Pass `nil` to clear it (personal
    /// workspace). The re-minted JWT is persisted so later calls carry the new
    /// active-org claim. Returns the new active organization id.
    @discardableResult
    public func setActiveOrganization(_ organizationId: String?) async throws -> String? {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        let body: [String: Any] = ["active_organization_id": organizationId ?? NSNull()]
        let result = try await authedDecode(
            SessionTouchResponse.self, "POST",
            "/v1/client/sessions/\(stored.sessionId)/touch", json: body
        )
        // Persist the rotated JWT; the touch response carries no new refresh token.
        try tokenStore.save(AtlasSession(
            sessionId: result.id ?? stored.sessionId,
            token: result.jwt,
            refreshToken: stored.refreshToken
        ))
        return result.lastActiveOrganizationId
    }
}

// MARK: - sessions / devices

extension AtlasClient {
    /// The signed-in user's active devices (`GET /v1/client/sessions`). The one
    /// marked `current` is this device.
    public func sessions() async throws -> [DeviceSession] {
        let envelope = try await authedDecode(
            ListEnvelope<DeviceSession>.self, "GET", "/v1/client/sessions"
        )
        return envelope.data
    }

    /// Revoke one device by id (`POST /v1/client/sessions/:id/revoke`) — sign that
    /// device out. Revoking the current session also clears local storage.
    public func revokeSession(id: String) async throws {
        try await authedSend("POST", "/v1/client/sessions/\(id)/revoke")
        if let stored = try tokenStore.load(), stored.sessionId == id {
            try tokenStore.clear()
        }
    }

    /// Sign out of every OTHER device (`POST /v1/client/sessions/revoke_all`); the
    /// current session is spared. Returns how many were revoked.
    @discardableResult
    public func revokeOtherSessions() async throws -> Int {
        let result = try await authedDecode(
            RevokeAllResponse.self, "POST", "/v1/client/sessions/revoke_all"
        )
        return result.sessionsRevoked ?? 0
    }
}

// MARK: - /me email addresses

extension AtlasClient {
    /// Add an email address (`POST /v1/client/me/email_addresses`). It starts
    /// unverified; a code is mailed to it — submit it with ``verifyEmailAddress``.
    @discardableResult
    public func addEmailAddress(_ email: String) async throws -> EmailAddressResult {
        try await authedDecode(
            EmailAddressResult.self, "POST", "/v1/client/me/email_addresses",
            json: ["email_address": email]
        )
    }

    /// Verify an email address with its emailed code
    /// (`POST /v1/client/me/email_addresses/:id/attempt_verification`).
    @discardableResult
    public func verifyEmailAddress(id: String, code: String) async throws -> EmailAddressResult {
        try await authedDecode(
            EmailAddressResult.self, "POST",
            "/v1/client/me/email_addresses/\(id)/attempt_verification", json: ["code": code]
        )
    }

    /// Make a (verified) address primary
    /// (`POST /v1/client/me/email_addresses/:id/primary`).
    @discardableResult
    public func setPrimaryEmailAddress(id: String) async throws -> EmailAddressResult {
        try await authedDecode(
            EmailAddressResult.self, "POST", "/v1/client/me/email_addresses/\(id)/primary"
        )
    }

    /// Remove an email address (`DELETE /v1/client/me/email_addresses/:id`). The
    /// server refuses to remove the last verified address.
    public func removeEmailAddress(id: String) async throws {
        try await authedSend("DELETE", "/v1/client/me/email_addresses/\(id)")
    }
}

// MARK: - /me external accounts

extension AtlasClient {
    /// Start linking a NEW OAuth provider to the signed-in user
    /// (`POST /v1/client/me/external_accounts/connect`). Navigate the browser / an
    /// `ASWebAuthenticationSession` to the returned `authorizationURL`.
    @discardableResult
    public func connectExternalAccount(
        provider: String,
        redirectURL: String,
        additionalScopes: [String]? = nil
    ) async throws -> ExternalAccountConnection {
        var body: [String: Any] = ["provider": provider, "redirect_url": redirectURL]
        if let additionalScopes { body["additional_scopes"] = additionalScopes }
        return try await authedDecode(
            ExternalAccountConnection.self, "POST",
            "/v1/client/me/external_accounts/connect", json: body
        )
    }

    /// Unlink an external account (`DELETE /v1/client/me/external_accounts/:id`).
    /// The server refuses to remove the user's only sign-in method.
    public func disconnectExternalAccount(id: String) async throws {
        try await authedSend("DELETE", "/v1/client/me/external_accounts/\(id)")
    }
}

// MARK: - /me password + profile

extension AtlasClient {
    /// Change the password of a signed-in account that already has one
    /// (`POST /v1/client/me/change_password`). Session-only.
    public func changePassword(current: String, new: String) async throws {
        try await authedSend(
            "POST", "/v1/client/me/change_password",
            json: ["current_password": current, "new_password": new]
        )
    }

    /// Set a FIRST password on an account that has none — a guest or OAuth-only
    /// user (`POST /v1/client/me/set_password`).
    public func setPassword(_ password: String) async throws {
        try await authedSend("POST", "/v1/client/me/set_password", json: ["password": password])
    }

    /// Update the signed-in user's profile and `unsafe_metadata`
    /// (`PATCH /v1/client/me`). `public_metadata` is deliberately not accepted —
    /// it is writable only with a backend key. Pass only the fields to change.
    @discardableResult
    public func updateProfile(
        firstName: String? = nil,
        lastName: String? = nil,
        username: String? = nil,
        locale: String? = nil,
        unsafeMetadata: [String: JSONValue]? = nil
    ) async throws -> AtlasUser {
        var body: [String: Any] = [:]
        if let firstName { body["first_name"] = firstName }
        if let lastName { body["last_name"] = lastName }
        if let username { body["username"] = username }
        if let locale { body["locale"] = locale }
        if let unsafeMetadata { body["unsafe_metadata"] = unsafeMetadata.foundationObject }
        return try await authedDecode(AtlasUser.self, "PATCH", "/v1/client/me", json: body)
    }
}
