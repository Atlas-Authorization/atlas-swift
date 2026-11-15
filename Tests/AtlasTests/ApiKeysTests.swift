import XCTest
@testable import Atlas

final class ApiKeysTests: XCTestCase {
    override func setUp() { super.setUp(); MockURLProtocol.reset() }

    private func client(token: String = "jwt") -> (AtlasClient, InMemoryTokenStore) {
        let store = InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: token, refreshToken: "rt"))
        return (AtlasClient(publishableKey: "pk_test_123", frontendApi: "clerk.example.com", tokenStore: store, urlSession: MockURLProtocol.makeSession()), store)
    }

    private func body(_ i: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[i]) as? [String: Any])
    }

    private let key = #"{"object":"api_key","id":"ak_1","subject_type":"user","subject_id":"user_1","name":"CI","prefix":"ak_live_abcd","scopes":["calls:read"],"last_used_at":null,"expires_at":null,"revoked_at":null,"created_at":1700000000000}"#

    func testListUsesOrganizationQueryAndDecodesLimits() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"data":["# + key + #"],"allowed_scopes":["calls:read","calls:write"],"max_active_keys":5,"active_count":1}"#)
        let (c, _) = client()
        let list = try await c.apiKeys(organizationId: "org_1", bound: true)
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.query, "organization_id=org_1&subject_type=user")
        XCTAssertEqual(list.keys.first?.prefix, "ak_live_abcd")
        XCTAssertEqual(list.allowedScopes.count, 2)
        XCTAssertEqual(list.maxActiveKeys, 5)
        XCTAssertTrue(list.keys[0].isActive())
    }

    func testCreateReturnsSecretOnce() async throws {
        MockURLProtocol.enqueue(status: 201, json: String(key.dropLast()) + #","secret":"ak_live_secret"}"#)
        let (c, _) = client()
        let created = try await c.createApiKey(name: "CI", expiresInSeconds: 86_400, scopes: ["calls:read"], organizationId: "org_1")
        XCTAssertEqual(created.secret, "ak_live_secret")
        XCTAssertEqual(created.key.id, "ak_1")
        let b = try body(0)
        XCTAssertEqual(b["name"] as? String, "CI")
        XCTAssertEqual(b["expires_in_seconds"] as? Int, 86_400)
        XCTAssertEqual(b["organization_id"] as? String, "org_1")
        XCTAssertNil(b["expires_at"])
    }

    func testStaleSessionSurfacesStepUp() async throws {
        MockURLProtocol.enqueue(status: 403, json: #"{"errors":[{"code":"STEP_UP_REQUIRED","message":"Re-authenticate"}]}"#)
        let (c, _) = client()
        do { _ = try await c.createApiKey(); XCTFail("expected an error") } catch let e as AtlasError {
            XCTAssertTrue(e.isStepUpRequired)
        }
    }

    func testRenameAndRevoke() async throws {
        MockURLProtocol.enqueue(status: 200, json: key)
        let (c, _) = client()
        _ = try await c.renameApiKey(id: "ak_1", name: nil)
        XCTAssertEqual(MockURLProtocol.recorded[0].httpMethod, "PATCH")
        XCTAssertTrue(try body(0)["name"] is NSNull)
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"api_key","id":"ak_1","revoked":true}"#)
        try await c.revokeApiKey(id: "ak_1")
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/me/api_keys/ak_1/revoke")
    }

    func testStepUpPersistsFreshJwt() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"session","id":"sess_1","jwt":"jwt_fresh"}"#)
        let (c, store) = client()
        try await c.stepUp(strategy: "password", password: "pw")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/step_up")
        XCTAssertEqual(try body(0)["strategy"] as? String, "password")
        XCTAssertEqual(try store.load()?.token, "jwt_fresh")
        XCTAssertEqual(try store.load()?.refreshToken, "rt")
    }

    func testActiveOrganizationFromTokenClaim() {
        // header.{"org_id":"org_9"}.sig
        let payload = Data(#"{"org_id":"org_9"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(client(token: "h.\(payload).s").0.activeOrganizationId(), "org_9")
        XCTAssertNil(client(token: "opaque").0.activeOrganizationId())
    }
}

final class StepUpTests: XCTestCase {
    override func setUp() { super.setUp(); MockURLProtocol.reset() }

    private func client() -> (AtlasClient, InMemoryTokenStore) {
        let store = InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt"))
        return (AtlasClient(publishableKey: "pk_test_123", frontendApi: "clerk.example.com", tokenStore: store, urlSession: MockURLProtocol.makeSession()), store)
    }

    func testPasskeyBodyHasNoHandleAndBase64Url() throws {
        let body = stepUpPasskeyBody(challenge: "ch", result: PasskeyAssertionResult(
            credentialID: Data([251, 255]), authenticatorData: Data([1]), clientDataJSON: Data([2]), signature: Data([3])))
        XCTAssertEqual(body["strategy"] as? String, "passkey")
        XCTAssertEqual(body["challenge"] as? String, "ch")
        XCTAssertEqual(body["credential_id"] as? String, "-_8")
        XCTAssertNil(body["handle"])
    }

    func testPushBeginAndPendingThenApproved() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"number_match":"42"}"#)
        let (c, store) = client()
        let challenge = try await c.beginPushStepUp()
        XCTAssertEqual(challenge.numberMatch, "42")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/step_up/push")
        MockURLProtocol.enqueue(status: 202, json: #"{"status":"pending"}"#)
        let pending = try await c.stepUpPush()
        XCTAssertFalse(pending)
        XCTAssertEqual(try store.load()?.token, "jwt")
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_1","jwt":"jwt_push"}"#)
        let approved = try await c.stepUpPush()
        XCTAssertTrue(approved)
        XCTAssertEqual(try store.load()?.token, "jwt_push")
    }
}
