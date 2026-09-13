import XCTest
@testable import Atlas

final class AtlasClientTests: XCTestCase {
    let pk = "pk_test_123"
    let frontendApi = "clerk.example.com"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeClient(store: TokenStore = InMemoryTokenStore()) -> AtlasClient {
        AtlasClient(
            publishableKey: pk,
            frontendApi: frontendApi,
            tokenStore: store,
            urlSession: MockURLProtocol.makeSession()
        )
    }

    private func body(at index: Int) throws -> [String: Any] {
        let data = MockURLProtocol.recordedBodies[index]
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: base URL + auth header

    func testResolvesBareHostToHTTPS() {
        let client = makeClient()
        XCTAssertEqual(client.baseURL.absoluteString, "https://clerk.example.com")
    }

    func testResolvesFullOriginUntouched() {
        let client = AtlasClient(
            publishableKey: pk,
            frontendApi: "http://localhost:4000/",
            tokenStore: InMemoryTokenStore(),
            urlSession: MockURLProtocol.makeSession()
        )
        // Trailing slash trimmed, scheme preserved.
        XCTAssertEqual(client.baseURL.absoluteString, "http://localhost:4000")
    }

    func testEveryRequestCarriesPublishableKeyAndBaseURL() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_1","status":"needs_first_factor"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_1","status":"complete","ticket":"tk_1"}"#)
        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"object":"session","id":"sess_1","jwt":"jwt_abc","expires_in":60}"#,
            headers: ["Set-Cookie": "__atlas_rt=rt_xyz; Path=/v1; HttpOnly"]
        )
        MockURLProtocol.enqueue(status: 200, json: Self.userJSON)

        let client = makeClient()
        _ = try await client.signIn(email: "a@b.com", password: "hunter2")

        // The very first request created the attempt at the right URL...
        let first = MockURLProtocol.recorded[0]
        XCTAssertEqual(first.url?.absoluteString, "https://clerk.example.com/v1/client/sign_ins")
        // ...and every request presented the publishable key.
        for request in MockURLProtocol.recorded {
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-publishable-key"), pk)
        }
    }

    // MARK: password sign-in — endpoint + body mutation-checks + token storage

    func testPasswordSignInHitsExactEndpointsWithExactBodies() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_42","status":"needs_first_factor"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_42","status":"complete","ticket":"tk_9"}"#)
        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"object":"session","id":"sess_9","jwt":"jwt_final","expires_in":60}"#,
            headers: ["Set-Cookie": "__atlas_rt=rt_final; Path=/v1; HttpOnly"]
        )
        MockURLProtocol.enqueue(status: 200, json: Self.userJSON)

        let store = InMemoryTokenStore()
        let client = makeClient(store: store)
        let user = try await client.signIn(email: "a@b.com", password: "hunter2")

        // Step 1: create attempt with the identifier (never the password).
        XCTAssertEqual(
            MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ins")
        XCTAssertEqual(try body(at: 0)["identifier"] as? String, "a@b.com")
        XCTAssertNil(try body(at: 0)["password"], "the password must not leak into the create call")

        // Step 2: first factor with strategy=password on the attempt id.
        XCTAssertEqual(
            MockURLProtocol.recorded[1].url?.path, "/v1/client/sign_ins/sia_42/attempt_first_factor")
        XCTAssertEqual(try body(at: 1)["strategy"] as? String, "password")
        XCTAssertEqual(try body(at: 1)["password"] as? String, "hunter2")

        // Step 3: exchange the completion ticket.
        XCTAssertEqual(MockURLProtocol.recorded[2].url?.path, "/v1/client/tickets/exchange")
        XCTAssertEqual(try body(at: 2)["attempt_id"] as? String, "sia_42")
        XCTAssertEqual(try body(at: 2)["ticket"] as? String, "tk_9")

        // Token stored: the JWT from the exchange and the refresh cookie captured.
        let stored = try XCTUnwrap(try store.load())
        XCTAssertEqual(stored.token, "jwt_final")
        XCTAssertEqual(stored.refreshToken, "rt_final")
        XCTAssertEqual(stored.sessionId, "sess_9")

        XCTAssertEqual(user.id, "user_1")
    }

    // MARK: 4xx -> AtlasError with code (mutation-check on the envelope)

    func testWrongPasswordSurfacesApiErrorWithCode() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_1","status":"needs_first_factor"}"#)
        MockURLProtocol.enqueue(
            status: 422,
            json: #"{"errors":[{"code":"form_password_incorrect","message":"Incorrect password.","param":"password"}]}"#
        )

        let client = makeClient()
        do {
            _ = try await client.signIn(email: "a@b.com", password: "wrong")
            XCTFail("expected an AtlasError")
        } catch let error as AtlasError {
            XCTAssertEqual(error.code, "form_password_incorrect")
            XCTAssertEqual(error.status, 422)
            XCTAssertEqual(error.message, "Incorrect password.")
        }
    }

    func testMalformedErrorBodyStillYieldsAcode() async throws {
        MockURLProtocol.enqueue(status: 500, json: "not json at all")
        let client = makeClient()
        do {
            _ = try await client.oauthAuthorizeURL(provider: "google", redirectURI: "app://cb")
            XCTFail("expected an AtlasError")
        } catch let error as AtlasError {
            XCTAssertEqual(error.status, 500)
            XCTAssertEqual(error.code, "unexpected")
        }
    }

    // MARK: currentUser decodes

    func testCurrentUserDecodesFullShape() async throws {
        let store = InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt"))
        MockURLProtocol.enqueue(status: 200, json: Self.userJSON)

        let client = makeClient(store: store)
        let user = try await client.currentUser()

        XCTAssertEqual(user.id, "user_1")
        XCTAssertEqual(user.firstName, "Ada")
        XCTAssertEqual(user.primaryEmailId, "email_1")
        XCTAssertEqual(user.emailAddresses?.first?.emailAddress, "ada@example.com")
        XCTAssertEqual(user.emailAddresses?.first?.verified, true)
        XCTAssertEqual(user.externalAccounts?.first?.provider, "google")
        XCTAssertEqual(user.publicMetadata?["plan"]?.stringValue, "pro")

        // The authenticated call presented the refresh cookie.
        let cookie = MockURLProtocol.recorded.last?.value(forHTTPHeaderField: "Cookie")
        XCTAssertTrue(cookie?.contains("__atlas_rt=rt") == true)
        XCTAssertTrue(cookie?.contains("__session=jwt") == true)
    }

    func testCurrentUserWithoutSessionThrowsNotSignedIn() async {
        let client = makeClient() // empty store
        do {
            _ = try await client.currentUser()
            XCTFail("expected notSignedIn")
        } catch let error as AtlasError {
            guard case .notSignedIn = error else {
                return XCTFail("expected .notSignedIn, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: OAuth authorize URL

    func testOAuthAuthorizeURLReturnsProviderURL() async throws {
        MockURLProtocol.enqueue(
            status: 201,
            json: #"{"object":"sign_in_attempt","id":"sia_o","status":"needs_oauth_callback","authorization_url":"https://accounts.google.com/o/oauth2/auth?x=1"}"#
        )
        let client = makeClient()
        let url = try await client.oauthAuthorizeURL(provider: "google", redirectURI: "myapp://callback")

        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ins/oauth")
        XCTAssertEqual(try body(at: 0)["provider"] as? String, "google")
        XCTAssertEqual(try body(at: 0)["redirect_url"] as? String, "myapp://callback")
    }

    // MARK: refresh rotates the stored token

    func testRefreshRotatesStoredToken() async throws {
        let store = InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "old", refreshToken: "rt_old"))
        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"object":"session_tokens","jwt":"jwt_new","session_id":"sess_1","expires_in":60}"#,
            headers: ["Set-Cookie": "__atlas_rt=rt_new; Path=/v1; HttpOnly"]
        )
        let client = makeClient(store: store)
        let rotated = try await client.refresh()

        XCTAssertEqual(rotated.token, "jwt_new")
        XCTAssertEqual(rotated.refreshToken, "rt_new")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sessions/sess_1/tokens")
        XCTAssertEqual(try store.load()?.token, "jwt_new")
    }

    // MARK: sign-out clears storage even on network failure

    func testSignOutClearsStoreEvenWhenRevokeFails() async throws {
        let store = InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt"))
        // No stub enqueued: the revoke request fails at transport. Store must
        // still be cleared.
        let client = makeClient(store: store)
        try await client.signOut()
        XCTAssertNil(try store.load())
    }

    // MARK: token store round-trip

    func testInMemoryTokenStoreRoundTrip() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load())

        let session = AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt")
        try store.save(session)
        XCTAssertEqual(try store.load(), session)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testAtlasSessionCodableRoundTrip() throws {
        // The Keychain impl persists this exact JSON; guard its shape here so the
        // Keychain store (not exercisable in this test env) stays correct.
        let session = AtlasSession(sessionId: "sess_1", token: "jwt_abc", refreshToken: "rt_xyz")
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AtlasSession.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    // MARK: fixtures

    static let userJSON = #"""
    {
      "object": "user",
      "id": "user_1",
      "first_name": "Ada",
      "last_name": "Lovelace",
      "username": null,
      "image_url": "https://img.example.com/a.png",
      "locale": "en-US",
      "public_metadata": { "plan": "pro" },
      "unsafe_metadata": {},
      "mfa_enabled": false,
      "has_password": true,
      "created_at": 1700000000000,
      "primary_email_id": "email_1",
      "email_addresses": [
        { "object": "email_address", "id": "email_1", "email_address": "ada@example.com", "verified": true, "primary": true }
      ],
      "external_accounts": [
        { "object": "external_account", "id": "ext_1", "provider": "google", "provider_email": "ada@gmail.com", "connected_at": 1700000000000 }
      ],
      "passkeys": []
    }
    """#
}
