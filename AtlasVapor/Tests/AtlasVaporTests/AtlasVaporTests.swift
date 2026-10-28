import Crypto
import Foundation
import XCTVapor

@testable import AtlasVapor

private let issuer = "https://auth.example.com"
private let party = "https://app.example.com"

private func b64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// ES256 keys and tokens minted with swift-crypto, so the verifier is exercised against independently produced JWTs.
private struct Minter {
    let key = P256.Signing.PrivateKey()
    let kid: String

    var jwks: String {
        let raw = key.publicKey.rawRepresentation // x || y
        return #"{"keys":[{"kty":"EC","crv":"P-256","alg":"ES256","use":"sig","kid":"\#(kid)","x":"\#(b64url(raw.prefix(32)))","y":"\#(b64url(raw.suffix(32)))"}]}"#
    }

    func mint(_ overrides: [String: Any] = [:], alg: String = "ES256", expiresIn: TimeInterval = 3600) -> String {
        var claims: [String: Any] = [
            "iss": issuer, "sub": "user_1", "sid": "sess_1", "azp": party, "token_use": "session",
            "iat": Int(Date().timeIntervalSince1970) - 10, "exp": Int(Date().timeIntervalSince1970 + expiresIn),
        ]
        for (k, v) in overrides { claims[k] = v }
        let header = b64url(try! JSONSerialization.data(withJSONObject: ["alg": alg, "typ": "JWT", "kid": kid]))
        let payload = b64url(try! JSONSerialization.data(withJSONObject: claims))
        let signed = "\(header).\(payload)"
        let signature = try! key.signature(for: Data(signed.utf8)).rawRepresentation
        return "\(signed).\(b64url(signature))"
    }
}

private final class StaticSource: AtlasKeySource, @unchecked Sendable {
    var json: String
    var calls = 0
    init(_ json: String) { self.json = json }
    func jwksJSON(from url: String) async throws -> String {
        calls += 1
        return json
    }
}

final class AtlasVaporTests: XCTestCase {
    private func makeApp(_ minter: Minter, source: StaticSource? = nil) async throws -> (Application, StaticSource) {
        let app = try await Application.make(.testing)
        let source = source ?? StaticSource(minter.jwks)
        app.atlas.use(AtlasSessionVerifier(
            configuration: .init(issuer: issuer, jwksURL: "https://auth.example.com/jwks", authorizedParties: [party]),
            source: source))
        app.grouped(AtlasAuthMiddleware()).get("me") { req in try req.requireAtlasSession().userId }
        app.grouped(AtlasAuthMiddleware(required: false)).get("opt") { req in req.atlasSession?.userId ?? "anon" }
        app.grouped(AtlasAuthMiddleware(), AtlasRequireMiddleware(.permission("billing:read"))).get("billing") { _ in "ok" }
        return (app, source)
    }

    private func bearer(_ token: String) -> HTTPHeaders { ["Authorization": "Bearer \(token)"] }

    func testValidBearerTokenReachesTheRoute() async throws {
        let minter = Minter(kid: "k1")
        let (app, _) = try await makeApp(minter)
        defer { Task { try await app.asyncShutdown() } }
        try await app.test(.GET, "me", headers: bearer(minter.mint())) { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "user_1")
        }
    }

    func testSessionCookieIsReadWhenThereIsNoHeader() async throws {
        let minter = Minter(kid: "k1")
        let (app, _) = try await makeApp(minter)
        defer { Task { try await app.asyncShutdown() } }
        try await app.test(.GET, "me", headers: ["Cookie": "a=b; __session=\(minter.mint())"]) { res async in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testMissingExpiredForgedWrongIssuerAndWrongPartyAreRefused() async throws {
        let minter = Minter(kid: "k1")
        let (app, _) = try await makeApp(minter)
        defer { Task { try await app.asyncShutdown() } }
        let forged = Minter(kid: "k1") // same kid, different key
        let bad = [
            "not.a.jwt",
            minter.mint(expiresIn: -3600),
            forged.mint(),
            minter.mint(["iss": "https://evil.example.com"]),
            minter.mint(["azp": "https://other.example.com"]),
            minter.mint(["token_use": "access_token"]),
            minter.mint(alg: "none"),
        ]
        try await app.test(.GET, "me") { res async in XCTAssertEqual(res.status, .unauthorized) }
        for token in bad {
            try await app.test(.GET, "me", headers: bearer(token)) { res async in
                XCTAssertEqual(res.status, .unauthorized, "token should be refused: \(token.prefix(20))")
            }
        }
    }

    func testPermissionGateAnswers403ThenPasses() async throws {
        let minter = Minter(kid: "k1")
        let (app, _) = try await makeApp(minter)
        defer { Task { try await app.asyncShutdown() } }
        try await app.test(.GET, "billing", headers: bearer(minter.mint())) { res async in XCTAssertEqual(res.status, .forbidden) }
        let token = minter.mint(["org_id": "o1", "org_role": "admin", "org_permissions": ["billing:read"]])
        try await app.test(.GET, "billing", headers: bearer(token)) { res async in XCTAssertEqual(res.status, .ok) }
    }

    func testOptionalMiddlewareContinuesAnonymously() async throws {
        let minter = Minter(kid: "k1")
        let (app, _) = try await makeApp(minter)
        defer { Task { try await app.asyncShutdown() } }
        try await app.test(.GET, "opt") { res async in XCTAssertEqual(res.body.string, "anon") }
        try await app.test(.GET, "opt", headers: bearer("garbage")) { res async in XCTAssertEqual(res.body.string, "anon") }
    }

    func testAnUnreachableKeySetFailsClosed() async throws {
        let minter = Minter(kid: "k1")
        let source = StaticSource("")
        let (app, _) = try await makeApp(minter, source: source)
        defer { Task { try await app.asyncShutdown() } }
        try await app.test(.GET, "me", headers: bearer(minter.mint())) { res async in XCTAssertEqual(res.status, .unauthorized) }
    }

    func testAKeyRotationIsPickedUpButRefetchesAreThrottled() async throws {
        let old = Minter(kid: "old")
        let new = Minter(kid: "new")
        let source = StaticSource(old.jwks)
        let clock = ClockBox()
        let verifier = AtlasSessionVerifier(
            configuration: .init(issuer: issuer, jwksURL: "u", authorizedParties: [party]), source: source, now: { clock.now })
        _ = try await verifier.verify(old.mint())
        XCTAssertEqual(source.calls, 1)
        source.json = new.jwks
        // An unknown kid inside the throttle window does not refetch.
        do { _ = try await verifier.verify(new.mint()); XCTFail("should be refused") } catch {}
        XCTAssertEqual(source.calls, 1)
        clock.now = clock.now.addingTimeInterval(61)
        let session = try await verifier.verify(new.mint())
        XCTAssertEqual(session.userId, "user_1")
        XCTAssertEqual(source.calls, 2)
    }

    func testUnconfiguredAtlasIsA500NeverAPass() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        app.grouped(AtlasAuthMiddleware()).get("me") { _ in "no" }
        try await app.test(.GET, "me", headers: ["Authorization": "Bearer a.b.c"]) { res async in
            XCTAssertEqual(res.status, .internalServerError)
        }
    }
}

private final class ClockBox: @unchecked Sendable {
    var now = Date()
}
