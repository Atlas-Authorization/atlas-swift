import JWTKit
import Vapor

/// Fetches the JWKS with Vapor's HTTP client.
struct VaporKeySource: AtlasKeySource, @unchecked Sendable {
    let client: Client

    func jwksJSON(from url: String) async throws -> String {
        let response = try await client.get(URI(string: url))
        guard response.status == .ok, var body = response.body else { throw AtlasVerifyError.noKeys }
        return body.readString(length: body.readableBytes) ?? ""
    }
}

extension AtlasSession: Authenticatable {}

private struct AtlasVerifierKey: StorageKey {
    typealias Value = AtlasSessionVerifier
}

extension Application {
    /// Configure Atlas once at startup:
    /// `app.atlas.configure(.init(issuer: "https://auth.example.com", jwksURL: "https://auth.example.com/.well-known/jwks.json", authorizedParties: ["https://app.example.com"]))`
    public var atlas: Atlas { Atlas(application: self) }

    public struct Atlas {
        let application: Application

        public func configure(_ configuration: AtlasVerifierConfiguration) {
            application.storage[AtlasVerifierKey.self] = AtlasSessionVerifier(
                configuration: configuration, source: VaporKeySource(client: application.client))
        }

        /// Use your own verifier (for example one with a custom key source).
        public func use(_ verifier: AtlasSessionVerifier) {
            application.storage[AtlasVerifierKey.self] = verifier
        }

        public var verifier: AtlasSessionVerifier? { application.storage[AtlasVerifierKey.self] }
    }
}

extension Request {
    /// The verified Atlas session, when `AtlasAuthMiddleware` ran and the token verified.
    public var atlasSession: AtlasSession? { auth.get(AtlasSession.self) }

    /// The verified session or a 401.
    public func requireAtlasSession() throws -> AtlasSession {
        guard let session = atlasSession else { throw Abort(.unauthorized, headers: ["WWW-Authenticate": "Bearer"]) }
        return session
    }

    fileprivate var atlasToken: String? {
        if let authorization = headers.first(name: .authorization) {
            let parts = authorization.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                let token = parts[1].trimmingCharacters(in: .whitespaces)
                if !token.isEmpty { return token }
            }
        }
        if let cookie = cookies["__session"]?.string, !cookie.isEmpty { return cookie }
        return nil
    }
}

/// Verifies the Atlas session token of each request: `Authorization: Bearer`, else the `__session` cookie.
///
/// With `required: true` (the default) a request without a verified session is answered 401 before your
/// handler runs. With `required: false` the request continues anonymously and `req.atlasSession` is nil.
/// An unconfigured verifier is always a 500: the middleware never lets a request through unchecked.
public struct AtlasAuthMiddleware: AsyncMiddleware {
    public let required: Bool

    public init(required: Bool = true) { self.required = required }

    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let verifier = request.application.atlas.verifier else {
            throw Abort(.internalServerError, reason: "Atlas is not configured: call app.atlas.configure(...).")
        }
        if let token = request.atlasToken {
            do {
                request.auth.login(try await verifier.verify(token))
            } catch {
                if required { throw Abort(.unauthorized, headers: ["WWW-Authenticate": "Bearer"]) }
            }
        } else if required {
            throw Abort(.unauthorized, headers: ["WWW-Authenticate": "Bearer"])
        }
        return try await next.respond(to: request)
    }
}

/// Requires the verified session to hold a permission or role (403 otherwise). Put it after `AtlasAuthMiddleware`.
public struct AtlasRequireMiddleware: AsyncMiddleware {
    public enum Requirement: Sendable {
        case permission(String)
        case role(String)
        case appRole(String)
        case appPermission(String)
    }

    let requirement: Requirement

    public init(_ requirement: Requirement) { self.requirement = requirement }

    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let session = try request.requireAtlasSession()
        let allowed: Bool
        switch requirement {
        case .permission(let p): allowed = session.has(permission: p)
        case .role(let r): allowed = session.has(role: r)
        case .appRole(let r): allowed = session.has(appRole: r)
        case .appPermission(let p): allowed = session.has(appPermission: p)
        }
        guard allowed else { throw Abort(.forbidden) }
        return try await next.respond(to: request)
    }
}
