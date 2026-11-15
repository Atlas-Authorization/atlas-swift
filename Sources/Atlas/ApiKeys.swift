import Foundation

/// End-user API key self-service over `/v1/client/me/api_keys`: the signed-in
/// user's own `ak_` keys, or (with `organizationId`) an organization's. The
/// feature is off until the application enables it (a 403 on the list). Creating
/// a key needs a recent re-authentication: a stale session throws an
/// ``AtlasError`` with code `STEP_UP_REQUIRED`; re-authenticate, then create again.

/// An API key as its owner sees it. The secret is never part of it.
public struct UserApiKey: Decodable, Sendable, Equatable {
    public let id: String
    /// `user` or `organization`.
    public let subjectType: String
    public let subjectId: String
    public let name: String?
    /// The public `ak_` head: recognises a key, cannot be used as one.
    public let prefix: String
    public let type: String?
    public let scopes: [String]?
    public let lastUsedAt: Double?
    public let expiresAt: Double?
    public let revokedAt: Double?
    /// Why it was revoked when the owner did not.
    public let revokedReason: String?
    public let organizationId: String?
    public let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, prefix, type, scopes
        case subjectType = "subject_type"
        case subjectId = "subject_id"
        case lastUsedAt = "last_used_at"
        case expiresAt = "expires_at"
        case revokedAt = "revoked_at"
        case revokedReason = "revoked_reason"
        case organizationId = "organization_id"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        subjectType = try c.decodeIfPresent(String.self, forKey: .subjectType) ?? "user"
        subjectId = try c.decodeIfPresent(String.self, forKey: .subjectId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes)
        lastUsedAt = try c.decodeIfPresent(Double.self, forKey: .lastUsedAt)
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        revokedAt = try c.decodeIfPresent(Double.self, forKey: .revokedAt)
        revokedReason = try c.decodeIfPresent(String.self, forKey: .revokedReason)
        organizationId = try c.decodeIfPresent(String.self, forKey: .organizationId)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
    }

    /// Whether the key still works at `now`.
    public func isActive(now: Date = Date()) -> Bool {
        if revokedAt != nil { return false }
        if let expiresAt, expiresAt <= now.timeIntervalSince1970 * 1000 { return false }
        return true
    }
}

/// A created key: the key plus its one-time `secret`, shown exactly once.
public struct CreatedUserApiKey: Decodable, Sendable, Equatable {
    public let key: UserApiKey
    /// The plaintext `ak_` key. Store it now; it is never returned again.
    public let secret: String

    private enum SecretKey: String, CodingKey { case secret }

    public init(from decoder: Decoder) throws {
        key = try UserApiKey(from: decoder)
        secret = try decoder.container(keyedBy: SecretKey.self).decode(String.self, forKey: .secret)
    }
}

/// The user's keys with the limits of the instance.
public struct UserApiKeyList: Decodable, Sendable, Equatable {
    public let keys: [UserApiKey]
    /// The scopes a new key may carry.
    public let allowedScopes: [String]
    /// The most active keys this user (or organization) may hold; 0 when unknown.
    public let maxActiveKeys: Int
    public let activeCount: Int

    enum CodingKeys: String, CodingKey {
        case data
        case allowedScopes = "allowed_scopes"
        case maxActiveKeys = "max_active_keys"
        case activeCount = "active_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keys = try c.decodeIfPresent([UserApiKey].self, forKey: .data) ?? []
        allowedScopes = try c.decodeIfPresent([String].self, forKey: .allowedScopes) ?? []
        maxActiveKeys = try c.decodeIfPresent(Int.self, forKey: .maxActiveKeys) ?? 0
        activeCount = try c.decodeIfPresent(Int.self, forKey: .activeCount) ?? 0
    }
}

extension AtlasClient {
    /// The user's API keys, or an organization's with `organizationId`. With
    /// `bound`, your own keys bound to that organization instead.
    public func apiKeys(organizationId: String? = nil, type: String? = nil, bound: Bool = false) async throws -> UserApiKeyList {
        var items: [URLQueryItem] = []
        if let organizationId { items.append(URLQueryItem(name: "organization_id", value: organizationId)) }
        if bound, organizationId != nil { items.append(URLQueryItem(name: "subject_type", value: "user")) }
        if let type { items.append(URLQueryItem(name: "type", value: type)) }
        var components = URLComponents()
        components.queryItems = items.isEmpty ? nil : items
        let path = "/v1/client/me/api_keys" + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        return try await authedDecode(UserApiKeyList.self, "GET", path)
    }

    /// Create a key. `expiresInSeconds` and `expiresAt` (epoch milliseconds) are
    /// mutually exclusive. `organizationId` creates the organization's key;
    /// with `bindToOrganization`, your own key bound to that organization.
    public func createApiKey(
        name: String? = nil,
        expiresInSeconds: Int? = nil,
        expiresAt: Double? = nil,
        scopes: [String]? = nil,
        organizationId: String? = nil,
        bindToOrganization: Bool = false,
        type: String? = nil
    ) async throws -> CreatedUserApiKey {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let expiresInSeconds { body["expires_in_seconds"] = expiresInSeconds }
        if let expiresAt { body["expires_at"] = expiresAt }
        if let scopes { body["scopes"] = scopes }
        if let organizationId { body["organization_id"] = organizationId }
        if bindToOrganization { body["subject_type"] = "user" }
        if let type { body["type"] = type }
        return try await authedDecode(CreatedUserApiKey.self, "POST", "/v1/client/me/api_keys", json: body)
    }

    /// Rename a key; nil clears the name.
    @discardableResult
    public func renameApiKey(id: String, name: String?) async throws -> UserApiKey {
        try await authedDecode(UserApiKey.self, "PATCH", "/v1/client/me/api_keys/\(apiKeyPathComponent(id))", json: ["name": name ?? NSNull()])
    }

    /// Revoke a key. Immediate and permanent.
    public func revokeApiKey(id: String) async throws {
        try await authedSend("POST", "/v1/client/me/api_keys/\(apiKeyPathComponent(id))/revoke")
    }

    private func apiKeyPathComponent(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}

extension AtlasClient {
    /// The active organization id carried by the stored session token (`org_id`
    /// claim), or nil for the personal workspace / when signed out. Offline.
    public func activeOrganizationId() -> String? {
        guard let token = ((try? tokenStore.load()) ?? nil)?.token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["org_id"] as? String
    }
}

extension AtlasClient {
    /// Step-up re-authentication (`POST /v1/client/me/step_up`): re-prove one
    /// credential (`password`, `totp`, `backup_code`, `email_code`, `phone_code`)
    /// before a sensitive action such as creating an API key. The fresh session
    /// token is persisted. A pending push/duo answer (202) returns without one.
    public func stepUp(strategy: String, password: String? = nil, code: String? = nil) async throws {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        var body: [String: Any] = ["strategy": strategy]
        if let password { body["password"] = password }
        if let code { body["code"] = code }
        let (data, _) = try await authedSend("POST", "/v1/client/me/step_up", json: body)
        if let tokens = try? decode(SessionTokens.self, from: data) {
            try tokenStore.save(AtlasSession(
                sessionId: tokens.resolvedSessionId ?? stored.sessionId,
                token: tokens.jwt,
                refreshToken: stored.refreshToken
            ))
        }
    }
}
