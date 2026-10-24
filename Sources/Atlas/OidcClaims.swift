import Foundation

/// OIDC scope names for the device and token-exchange helpers.
public enum AtlasScopes {
    public static let openid = "openid"
    public static let profile = "profile"
    public static let email = "email"
    public static let offlineAccess = "offline_access"
    /// Adds the `orgs` claim — `[{ id, slug, role }]`, at most 20 — to the ID token
    /// and userinfo.
    public static let organizations = "organizations"

    /// `base` plus `organizations` (once), for helpers that take a scope list, e.g.
    /// ``AtlasClient/startDeviceSignIn(clientId:scopes:)``.
    public static func withOrganizations(_ base: [String] = ["openid", "profile", "email"]) -> [String] {
        base.contains(organizations) ? base : base + [organizations]
    }
}

/// One entry of the `orgs` claim (`organizations` scope).
public struct OidcOrganization: Sendable, Equatable {
    public let id: String
    public let slug: String?
    public let role: String?

    public init(id: String, slug: String? = nil, role: String? = nil) {
        self.id = id
        self.slug = slug
        self.role = role
    }
}

/// The enterprise SSO connection a sign-in came through (`sso_*` claims).
public struct OidcSso: Sendable, Equatable {
    public let connectionId: String
    public let tenantId: String?
    public let issuer: String?
    public let domain: String?

    public init(connectionId: String, tenantId: String? = nil, issuer: String? = nil, domain: String? = nil) {
        self.connectionId = connectionId
        self.tenantId = tenantId
        self.issuer = issuer
        self.domain = domain
    }
}

/// The organization and enterprise-SSO claims of an Atlas ID token, access token
/// or userinfo response.
///
/// - `org_id`, `org_slug`, `org_role`, `org_permissions`: the organization the
///   sign-in applies to (absent when none applies).
/// - `orgs`: every organization, with the `organizations` scope.
/// - `sso_connection_id`, `sso_tenant_id`, `sso_issuer`, `sso_domain`: present
///   only for sign-ins through an enterprise SSO connection.
public struct OidcClaims: Sendable, Equatable {
    public let orgId: String?
    public let orgSlug: String?
    public let orgRole: String?
    public let orgPermissions: [String]
    public let orgs: [OidcOrganization]
    public let sso: OidcSso?

    public init(
        orgId: String? = nil,
        orgSlug: String? = nil,
        orgRole: String? = nil,
        orgPermissions: [String] = [],
        orgs: [OidcOrganization] = [],
        sso: OidcSso? = nil
    ) {
        self.orgId = orgId
        self.orgSlug = orgSlug
        self.orgRole = orgRole
        self.orgPermissions = orgPermissions
        self.orgs = orgs
        self.sso = sso
    }

    /// Read the claims off a decoded claims object (userinfo, introspection, or a
    /// JWT payload).
    public init(claims: [String: JSONValue]) {
        func string(_ key: String) -> String? {
            if case let .string(value)? = claims[key] { return value }
            return nil
        }
        var permissions: [String] = []
        if case let .array(items)? = claims["org_permissions"] {
            permissions = items.compactMap { $0.stringValue }
        }
        var orgs: [OidcOrganization] = []
        if case let .array(items)? = claims["orgs"] {
            for item in items {
                guard case let .object(entry) = item, case let .string(id)? = entry["id"] else { continue }
                orgs.append(OidcOrganization(
                    id: id,
                    slug: entry["slug"]?.stringValue,
                    role: entry["role"]?.stringValue
                ))
            }
        }
        var sso: OidcSso?
        if let connection = string("sso_connection_id") {
            sso = OidcSso(
                connectionId: connection,
                tenantId: string("sso_tenant_id"),
                issuer: string("sso_issuer"),
                domain: string("sso_domain")
            )
        }
        self.init(
            orgId: string("org_id"),
            orgSlug: string("org_slug"),
            orgRole: string("org_role"),
            orgPermissions: permissions,
            orgs: orgs,
            sso: sso
        )
    }

    /// Read the claims off a JWT's payload. The signature is NOT verified here —
    /// use this for display and routing on a token your app just received from
    /// Atlas, never to authorize on a token that arrived from elsewhere. Returns
    /// `nil` for something that is not a JWT.
    public init?(jwt: String) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        self.init(claims: object)
    }
}
