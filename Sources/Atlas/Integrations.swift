import Foundation

/// A short-lived token for a configured identity integration — what
/// ``AtlasClient/getToken(for:spaceId:)`` resolves. Any service that verifies the
/// user with a JWT (the built-in presets `chatly`, `forumulate`, `cookiemunch`,
/// `referalli`, or a custom integration id) accepts it as the user's identity.
public struct IntegrationToken: Codable, Sendable, Equatable {
    public let jwt: String
    public let expiresIn: Int
    /// The integration id it was minted for (a preset or a custom id).
    public let integration: String
    /// The token's `aud`.
    public let audience: String
    /// Forumulate preset: the organization the reader belongs to.
    public let orgId: String?
    /// Forumulate preset: the space the token is for.
    public let spaceId: String?
    /// Forumulate preset: where the reader's browser redeems the token.
    public let redeemUrl: String?

    public init(
        jwt: String,
        expiresIn: Int,
        integration: String,
        audience: String,
        orgId: String? = nil,
        spaceId: String? = nil,
        redeemUrl: String? = nil
    ) {
        self.jwt = jwt
        self.expiresIn = expiresIn
        self.integration = integration
        self.audience = audience
        self.orgId = orgId
        self.spaceId = spaceId
        self.redeemUrl = redeemUrl
    }

    enum CodingKeys: String, CodingKey {
        case jwt, integration, audience
        case expiresIn = "expires_in"
        case orgId = "org_id"
        case spaceId = "space_id"
        case redeemUrl = "redeem_url"
    }
}

/// An integration token for a Sign in with Atlas user (see
/// ``AtlasClient/getAtlasIdToken(for:accessToken:origin:dpopProof:)``).
public struct AtlasIdIntegrationToken: Codable, Sendable, Equatable {
    public let jwt: String
    public let expiresIn: Int
    public let integration: String
    public let audience: String
    /// The Sign in with Atlas issuer: the token's `iss`.
    public let issuer: String
    /// Where the receiving service fetches the keys to verify it.
    public let jwksUri: String

    public init(jwt: String, expiresIn: Int, integration: String, audience: String, issuer: String, jwksUri: String) {
        self.jwt = jwt
        self.expiresIn = expiresIn
        self.integration = integration
        self.audience = audience
        self.issuer = issuer
        self.jwksUri = jwksUri
    }

    enum CodingKeys: String, CodingKey {
        case jwt, integration, audience, issuer
        case expiresIn = "expires_in"
        case jwksUri = "jwks_uri"
    }
}

/// Percent-encode one URL path segment or query value.
private func integrationEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

/// The query string for a per-call audience (and any extra parameters), with a
/// leading `?`, or an empty string when there is nothing to send.
private func integrationQuery(
    spaceId: String? = nil,
    cbid: String? = nil,
    audience: String? = nil,
    audienceParams: [String: String] = [:]
) -> String {
    var parts: [String] = []
    if let spaceId, !spaceId.isEmpty { parts.append("space_id=\(integrationEncode(spaceId))") }
    for key in audienceParams.keys.sorted() {
        if let value = audienceParams[key], !value.isEmpty {
            parts.append("\(integrationEncode(key))=\(integrationEncode(value))")
        }
    }
    if let cbid, !cbid.isEmpty { parts.append("cbid=\(integrationEncode(cbid))") }
    if let audience, !audience.isEmpty { parts.append("audience=\(integrationEncode(audience))") }
    return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
}

extension AtlasClient {
    /// `getToken({ for })` for the signed-in session
    /// (`POST /v1/client/sessions/:id/integration_tokens/:integration`): a
    /// short-lived token for a configured identity integration. The stored refresh
    /// cookie is presented, never rotated.
    ///
    /// Returns `nil` when the integration is not enabled (404). A refusal such as
    /// 401 or 403 throws ``AtlasError``; no stored session throws
    /// ``AtlasError/notSignedIn``.
    ///
    /// - Parameters:
    ///   - integration: the integration id (a preset such as `chatly`, or a custom id).
    ///   - spaceId: Forumulate preset only: the space to mint the reader token for.
    ///   - cbid: the per-call audience value for an integration whose `per_call_audience` is keyed on `cbid`.
    ///   - audience: the full audience to request; it must match the integration's per-call audience template or allow-list.
    ///   - audienceParams: extra named values for a per-call audience template (for example `["tenant": "t2"]`).
    ///
    /// An integration with a per-call audience mints a token only when the call
    /// supplies a matching value; otherwise no token is minted.
    public func getToken(
        for integration: String,
        spaceId: String? = nil,
        cbid: String? = nil,
        audience: String? = nil,
        audienceParams: [String: String] = [:]
    ) async throws -> IntegrationToken? {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        var path = "/v1/client/sessions/\(integrationEncode(stored.sessionId))/integration_tokens/\(integrationEncode(integration))"
        path += integrationQuery(spaceId: spaceId, cbid: cbid, audience: audience, audienceParams: audienceParams)
        do {
            let (data, _) = try await authedSend("POST", path)
            return try decode(IntegrationToken.self, from: data)
        } catch let error as AtlasError {
            if error.status == 404 { return nil }
            throw error
        }
    }

    /// `getToken({ for })` for a user who signed in with Sign in with Atlas (not a
    /// session of this instance), from an app with no server of its own
    /// (`POST /v1/client/integrations/:integration/atlas_id_tokens`).
    ///
    /// The user's Sign in with Atlas access token goes as `Authorization: Bearer`,
    /// or as `DPoP` with `dpopProof` when the token is DPoP-bound. Atlas checks the
    /// request's `Origin` against the web origins of the Sign in with Atlas app the
    /// token was issued to; a native app that shares that app's registration passes
    /// one of those origins as `origin`. No cookie is sent.
    ///
    /// Returns `nil` when the integration is not enabled for Sign in with Atlas
    /// users (404). Other refusals — 401 for a token Atlas does not accept, 403
    /// `ORIGIN_NOT_ALLOWED` — throw ``AtlasError``.
    ///
    /// `cbid`, `audience` and `audienceParams` select the per-call audience, as on
    /// ``getToken(for:spaceId:cbid:audience:audienceParams:)``.
    public func getAtlasIdToken(
        for integration: String,
        accessToken: String,
        origin: String? = nil,
        dpopProof: String? = nil,
        cbid: String? = nil,
        audience: String? = nil,
        audienceParams: [String: String] = [:]
    ) async throws -> AtlasIdIntegrationToken? {
        var headers: [String: String] = [:]
        if let dpopProof {
            headers["Authorization"] = "DPoP \(accessToken)"
            headers["DPoP"] = dpopProof
        } else {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        if let origin, !origin.isEmpty { headers["Origin"] = origin }
        let path = "/v1/client/integrations/\(integrationEncode(integration))/atlas_id_tokens?publishable_key=\(integrationEncode(publishableKey))"
            + integrationQuery(cbid: cbid, audience: audience, audienceParams: audienceParams).replacingOccurrences(of: "?", with: "&")
        let (data, response) = try await sendJSON(
            "POST", path, json: nil, refreshCookie: nil, extraHeaders: headers
        )
        if response.statusCode == 404 { return nil }
        try throwIfError(status: response.statusCode, data: data)
        return try decode(AtlasIdIntegrationToken.self, from: data)
    }
}
