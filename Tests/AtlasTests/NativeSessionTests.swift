import XCTest
@testable import Atlas

/// Exercises the cookie-free native-session surface against the same
/// `MockURLProtocol` queue the `AtlasClientTests` use: token-exchange happy +
/// failure paths, a cookie-free rotate, and the manager's persistence +
/// lazy-refresh behaviour.
final class NativeSessionTests: XCTestCase {
    let pk = "pk_test_123"
    let clientId = "client_first_party"
    let baseURL = URL(string: "https://clerk.example.com")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func mockSession() -> URLSession { MockURLProtocol.makeSession() }

    // MARK: exchangeForSession — happy path

    func testExchangeForSessionParsesSessionAndPostsForm() async throws {
        MockURLProtocol.enqueue(
            status: 200,
            json: #"""
            {
              "access_token": "sess_jwt_1",
              "issued_token_type": "urn:atlas:token-type:session",
              "token_type": "Bearer",
              "expires_in": 60,
              "refresh_token": "rt_1",
              "session_id": "sess_abc"
            }
            """#
        )

        let session = await exchangeForSession(
            baseURL: baseURL,
            clientId: clientId,
            accessToken: "oauth_at_xyz",
            urlSession: mockSession()
        )

        let unwrapped = try XCTUnwrap(session)
        XCTAssertEqual(unwrapped.sessionToken, "sess_jwt_1")
        XCTAssertEqual(unwrapped.refreshToken, "rt_1")
        XCTAssertEqual(unwrapped.sessionId, "sess_abc")
        XCTAssertEqual(unwrapped.expiresInSeconds, 60)

        // The request hit /oauth2/token as a form-urlencoded token-exchange.
        let request = MockURLProtocol.recorded[0]
        XCTAssertEqual(request.url?.path, "/oauth2/token")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "content-type"),
            "application/x-www-form-urlencoded"
        )
        let body = String(decoding: MockURLProtocol.recordedBodies[0], as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange"))
        XCTAssertTrue(body.contains("subject_token=oauth_at_xyz"))
        XCTAssertTrue(body.contains("client_id=client_first_party"))
        XCTAssertTrue(body.contains("requested_token_type=urn%3Aatlas%3Atoken-type%3Asession"))
    }

    // MARK: exchangeForSession — failure paths fail soft (nil, never throw)

    func testExchangeForSessionReturnsNilOnNon2xx() async {
        MockURLProtocol.enqueue(status: 400, json: #"{"error":"invalid_grant"}"#)
        let session = await exchangeForSession(
            baseURL: baseURL, clientId: clientId, accessToken: "bad", urlSession: mockSession()
        )
        XCTAssertNil(session)
    }

    func testExchangeForSessionReturnsNilWhenSessionIdMissing() async {
        // A body with a token but no session_id is unusable — the refresh path
        // needs the id — so it is reported as a failed exchange.
        MockURLProtocol.enqueue(status: 200, json: #"{"access_token":"sess_jwt_1","expires_in":60}"#)
        let session = await exchangeForSession(
            baseURL: baseURL, clientId: clientId, accessToken: "at", urlSession: mockSession()
        )
        XCTAssertNil(session)
    }

    func testExchangeForSessionReturnsNilOnTransportFailure() async {
        // No stub enqueued -> MockURLProtocol fails the request at transport.
        let session = await exchangeForSession(
            baseURL: baseURL, clientId: clientId, accessToken: "at", urlSession: mockSession()
        )
        XCTAssertNil(session)
    }

    // MARK: refreshNativeSession — rotates the refresh token

    func testRefreshNativeSessionRotatesRefreshToken() async throws {
        MockURLProtocol.enqueue(
            status: 200,
            json: #"""
            {"object":"session_tokens","jwt":"sess_jwt_2","session_id":"sess_abc","expires_in":60,"refresh_token":"rt_2"}
            """#
        )

        let rotated = await refreshNativeSession(
            baseURL: baseURL,
            publishableKey: pk,
            sessionId: "sess_abc",
            refreshToken: "rt_1",
            urlSession: mockSession()
        )

        let unwrapped = try XCTUnwrap(rotated)
        XCTAssertEqual(unwrapped.sessionToken, "sess_jwt_2")
        XCTAssertEqual(unwrapped.refreshToken, "rt_2", "the refresh token must rotate")
        XCTAssertEqual(unwrapped.sessionId, "sess_abc")

        let request = MockURLProtocol.recorded[0]
        XCTAssertEqual(request.url?.path, "/v1/client/sessions/sess_abc/tokens")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-publishable-key"), pk)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[0]) as? [String: Any]
        )
        XCTAssertEqual(body["refresh_token"] as? String, "rt_1")
    }

    func testRefreshKeepsPresentedTokenWhenServerOmitsRotation() async throws {
        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"object":"session_tokens","jwt":"sess_jwt_2","session_id":"sess_abc","expires_in":60}"#
        )
        let rotated = await refreshNativeSession(
            baseURL: baseURL, publishableKey: pk, sessionId: "sess_abc",
            refreshToken: "rt_keep", urlSession: mockSession()
        )
        XCTAssertEqual(try XCTUnwrap(rotated).refreshToken, "rt_keep")
    }

    func testRefreshReturnsNilOnNon2xx() async {
        MockURLProtocol.enqueue(status: 401, json: #"{"errors":[{"code":"session_expired"}]}"#)
        let rotated = await refreshNativeSession(
            baseURL: baseURL, publishableKey: pk, sessionId: "sess_abc",
            refreshToken: "rt_dead", urlSession: mockSession()
        )
        XCTAssertNil(rotated)
    }

    // MARK: NativeSessionManager — exchange persists to the TokenStore

    func testManagerExchangePersistsRotatedSessionToStore() async throws {
        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"access_token":"sess_jwt_1","expires_in":60,"refresh_token":"rt_1","session_id":"sess_abc"}"#
        )
        let store = InMemoryTokenStore()
        let manager = NativeSessionManager(
            publishableKey: pk,
            frontendApi: "clerk.example.com",
            clientId: clientId,
            tokenStore: store,
            urlSession: mockSession()
        )

        let session = await manager.exchange(accessToken: "oauth_at_xyz")
        XCTAssertEqual(try XCTUnwrap(session).sessionToken, "sess_jwt_1")

        // Persisted as the shared AtlasSession shape.
        let stored = try XCTUnwrap(try store.load())
        XCTAssertEqual(stored.token, "sess_jwt_1")
        XCTAssertEqual(stored.refreshToken, "rt_1")
        XCTAssertEqual(stored.sessionId, "sess_abc")

        // authHeaders carries the fresh bearer + publishable key.
        let headers = await manager.authHeaders()
        XCTAssertEqual(headers["Authorization"], "Bearer sess_jwt_1")
        XCTAssertEqual(headers["x-publishable-key"], pk)
    }

    // MARK: NativeSessionManager — token() lazily refreshes near expiry + persists

    func testManagerTokenRefreshesWhenExpiredAndPersistsRotation() async throws {
        // Seed a session that is already due for refresh (expires_in 0).
        let store = InMemoryTokenStore()
        let manager = NativeSessionManager(
            publishableKey: pk,
            frontendApi: "clerk.example.com",
            clientId: clientId,
            tokenStore: store,
            urlSession: mockSession()
        )
        await manager.setSession(
            NativeSession(sessionToken: "old", refreshToken: "rt_1", sessionId: "sess_abc", expiresInSeconds: 0)
        )

        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"object":"session_tokens","jwt":"fresh","session_id":"sess_abc","expires_in":60,"refresh_token":"rt_2"}"#
        )

        let token = await manager.token()
        XCTAssertEqual(token, "fresh", "an expired token is rotated before it is handed out")

        let rotatedStored = try XCTUnwrap(try store.load())
        XCTAssertEqual(rotatedStored.token, "fresh")
        XCTAssertEqual(rotatedStored.refreshToken, "rt_2")
    }

    func testManagerTokenKeepsCurrentTokenWhenRefreshFails() async {
        let manager = NativeSessionManager(
            publishableKey: pk,
            frontendApi: "clerk.example.com",
            tokenStore: InMemoryTokenStore(),
            urlSession: mockSession()
        )
        await manager.setSession(
            NativeSession(sessionToken: "still_valid", refreshToken: "rt_1", sessionId: "sess_abc", expiresInSeconds: 0)
        )
        // No stub -> the refresh fails at transport; the existing token stands.
        let token = await manager.token()
        XCTAssertEqual(token, "still_valid")
    }

    func testManagerTokenIsNilWhenSignedOut() async {
        let manager = NativeSessionManager(
            publishableKey: pk,
            frontendApi: "clerk.example.com",
            tokenStore: InMemoryTokenStore(),
            urlSession: mockSession()
        )
        let token = await manager.token()
        XCTAssertNil(token)
        let headers = await manager.authHeaders()
        XCTAssertEqual(headers, ["x-publishable-key": pk])
    }
}
