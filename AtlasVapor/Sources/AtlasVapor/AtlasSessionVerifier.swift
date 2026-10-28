import Foundation
import JWTKit

/// The verified Atlas session on a request.
public struct AtlasSession: Sendable {
    public let userId: String
    public let sessionId: String?
    public let orgId: String?
    public let orgRole: String?
    public let orgPermissions: [String]
    public let appRoles: [String]
    public let appPermissions: [String]
    public let authorizedParty: String?
    public let expiresAt: Date

    /// True when the session holds the organization permission.
    public func has(permission: String) -> Bool { orgPermissions.contains(permission) }
    /// True when the organization role matches.
    public func has(role: String) -> Bool { orgRole == role }
    public func has(appRole: String) -> Bool { appRoles.contains(appRole) }
    public func has(appPermission: String) -> Bool { appPermissions.contains(appPermission) }
}

public enum AtlasVerifyError: Error, Equatable, Sendable {
    case malformed
    case invalid
    /// No usable verification key (the key set is empty or unreachable).
    case noKeys
    case unauthorizedParty
}

public struct AtlasVerifierConfiguration: Sendable {
    /// Expected `iss`: your instance's frontend API origin. Required.
    public var issuer: String
    /// The instance's JWKS URL. Required.
    public var jwksURL: String
    /// Optional `azp` allowlist. When set, a token minted for another origin (or with none) is refused.
    public var authorizedParties: [String]
    /// How long a fetched key set is reused. Default 10 minutes.
    public var keyTTL: TimeInterval
    /// Least time between refetches triggered by an unknown `kid`. Default 60 seconds.
    public var refetchInterval: TimeInterval
    public var clockSkew: TimeInterval

    public init(
        issuer: String,
        jwksURL: String,
        authorizedParties: [String] = [],
        keyTTL: TimeInterval = 600,
        refetchInterval: TimeInterval = 60,
        clockSkew: TimeInterval = 5
    ) {
        self.issuer = issuer
        self.jwksURL = jwksURL
        self.authorizedParties = authorizedParties
        self.keyTTL = keyTTL
        self.refetchInterval = refetchInterval
        self.clockSkew = clockSkew
    }
}

/// Where the verifier gets the JWKS document. The default uses the Vapor client; tests supply a string.
public protocol AtlasKeySource: Sendable {
    func jwksJSON(from url: String) async throws -> String
}

struct AtlasSessionPayload: JWTPayload {
    var iss: IssuerClaim
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var nbf: NotBeforeClaim?
    var aud: AudienceClaim?
    var sid: String?
    var azp: String?
    var token_use: String?
    var org_id: String?
    var org_role: String?
    var org_permissions: [String]?
    var app_roles: [String]?
    var app_permissions: [String]?

    // Time and claim checks are made by AtlasSessionVerifier (with the clock skew and the injected clock).
    func verify(using algorithm: some JWTAlgorithm) throws {}
}

/// Verifies Atlas session tokens locally: signature against the cached JWKS (RS256, ES256), issuer,
/// expiry and not-before with clock skew, the `azp` allowlist, and the session/ID-token guard.
public actor AtlasSessionVerifier {
    private let configuration: AtlasVerifierConfiguration
    private let source: AtlasKeySource
    private let now: @Sendable () -> Date
    private var keys: JWTKeyCollection?
    private var kids: Set<String> = []
    private var fetchedAt: Date?
    private var lastFetchAttempt: Date?

    public init(configuration: AtlasVerifierConfiguration, source: AtlasKeySource, now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        self.source = source
        self.now = now
    }

    public func verify(_ token: String) async throws -> AtlasSession {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let header = Self.decodeJSON(String(parts[0])),
              let alg = header["alg"] as? String
        else { throw AtlasVerifyError.malformed }
        guard alg == "RS256" || alg == "ES256" else { throw AtlasVerifyError.invalid }
        let kid = header["kid"] as? String

        var collection = try await currentKeys()
        if let kid, !kids.contains(kid) {
            // An unknown key id: the instance may have rotated. Refetch, at most once per interval.
            collection = try await refreshedKeys(or: collection)
            guard kids.contains(kid) else { throw AtlasVerifyError.invalid }
        }

        let payload: AtlasSessionPayload
        do {
            payload = try await collection.verify(token, as: AtlasSessionPayload.self)
        } catch {
            throw AtlasVerifyError.invalid
        }
        return try check(payload)
    }

    private func check(_ p: AtlasSessionPayload) throws -> AtlasSession {
        let t = now()
        let skew = configuration.clockSkew
        guard p.iss.value == configuration.issuer else { throw AtlasVerifyError.invalid }
        guard p.exp.value.addingTimeInterval(skew) >= t else { throw AtlasVerifyError.invalid }
        if let nbf = p.nbf, nbf.value.addingTimeInterval(-skew) > t { throw AtlasVerifyError.invalid }
        guard !p.sub.value.isEmpty else { throw AtlasVerifyError.invalid }
        // A session token is positively marked; an OAuth access token or an ID token signed with the same key must not pass.
        if let use = p.token_use, use != "session" { throw AtlasVerifyError.invalid }
        if p.token_use == nil, p.aud != nil { throw AtlasVerifyError.invalid }
        if !configuration.authorizedParties.isEmpty {
            guard let azp = p.azp, configuration.authorizedParties.contains(azp) else { throw AtlasVerifyError.unauthorizedParty }
        }
        return AtlasSession(
            userId: p.sub.value, sessionId: p.sid, orgId: p.org_id, orgRole: p.org_role,
            orgPermissions: p.org_permissions ?? [], appRoles: p.app_roles ?? [], appPermissions: p.app_permissions ?? [],
            authorizedParty: p.azp, expiresAt: p.exp.value
        )
    }

    private func currentKeys() async throws -> JWTKeyCollection {
        if let keys, let fetchedAt, now().timeIntervalSince(fetchedAt) < configuration.keyTTL { return keys }
        return try await fetchKeys()
    }

    private func refreshedKeys(or current: JWTKeyCollection) async throws -> JWTKeyCollection {
        if let last = lastFetchAttempt, now().timeIntervalSince(last) < configuration.refetchInterval { return current }
        return try await fetchKeys()
    }

    private func fetchKeys() async throws -> JWTKeyCollection {
        lastFetchAttempt = now()
        do {
            let json = try await source.jwksJSON(from: configuration.jwksURL)
            guard let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["keys"] as? [[String: Any]], !entries.isEmpty
            else { throw AtlasVerifyError.noKeys }
            let collection = try await JWTKeyCollection().add(jwksJSON: json)
            keys = collection
            kids = Set(entries.compactMap { $0["kid"] as? String })
            fetchedAt = now()
            return collection
        } catch {
            // Keep serving a previous key set rather than failing every request on a blip; with none, fail closed.
            if let keys { return keys }
            throw AtlasVerifyError.noKeys
        }
    }

    private static func decodeJSON(_ segment: String) -> [String: Any]? {
        var s = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
