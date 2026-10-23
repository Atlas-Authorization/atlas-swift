import XCTest
@testable import Atlas

/// Upstream / SAML logout on sign-out, device approval from a signed-in phone,
/// and the passkey PRF value types.
final class ByMobileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeClient(store: TokenStore = InMemoryTokenStore()) -> AtlasClient {
        AtlasClient(
            publishableKey: "pk_test_123",
            frontendApi: "clerk.example.com",
            tokenStore: store,
            urlSession: MockURLProtocol.makeSession()
        )
    }

    private func signedIn() throws -> InMemoryTokenStore {
        let store = InMemoryTokenStore()
        try store.save(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt"))
        return store
    }

    private func body(_ index: Int) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[index]) as? [String: Any] ?? [:]
    }

    /// Records the URLs the client asks to open.
    final class Opened: @unchecked Sendable {
        var urls: [URL] = []
    }

    func testSignOutFollowsTheUpstreamLogoutURL() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"session","upstream_logout_url":"https://idp.example.com/logout?x=1","saml_logout_url":"http://insecure.example.com/slo"}"#)
        let store = try signedIn()
        let client = makeClient(store: store)
        let opened = Opened()
        client.logoutURLOpener = { url in opened.urls.append(url) }
        let result = try await client.signOut(returnURL: URL(string: "https://app.example.com/bye")!)
        XCTAssertEqual(MockURLProtocol.recorded.first?.url?.path, "/v1/client/sessions/sess_1/revoke")
        XCTAssertEqual(try body(0)["return_url"] as? String, "https://app.example.com/bye")
        XCTAssertEqual(result.upstreamLogoutURL?.absoluteString, "https://idp.example.com/logout?x=1")
        XCTAssertNil(result.samlLogoutURL, "a non-https URL is dropped")
        XCTAssertEqual(opened.urls.map(\.absoluteString), ["https://idp.example.com/logout?x=1"])
        XCTAssertNil(try store.load())
    }

    func testSignOutPrefersSamlAndCanSkipOpening() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"saml_logout_url":"https://clerk.example.com/v1/sso/saml/sso_1/slo/start?request=a"}"#)
        let client = makeClient(store: try signedIn())
        let opened = Opened()
        client.logoutURLOpener = { url in opened.urls.append(url) }
        let result = try await client.signOut(followLogoutURL: false)
        XCTAssertEqual(result.logoutURL?.absoluteString, "https://clerk.example.com/v1/sso/saml/sso_1/slo/start?request=a")
        XCTAssertTrue(opened.urls.isEmpty)
        XCTAssertEqual(AtlasSignOutResult(responseBody: Data("{}".utf8)), AtlasSignOutResult())
    }

    func testDeviceApprovalLookupApproveDeny() async throws {
        let da = #"{"object":"device_authorization","id":"da_1","user_code":"WDJB-MJHT","status":"pending","client":{"client_id":"oc_tv","name":"TV","first_party":true},"scopes":[{"scope":"openid","description":"Sign you in"}],"audience":null,"requires_step_up":true,"created_at":1,"expires_at":2}"#
        MockURLProtocol.enqueue(status: 200, json: da)
        MockURLProtocol.enqueue(status: 200, json: da.replacingOccurrences(of: "pending", with: "approved"))
        MockURLProtocol.enqueue(status: 200, json: da.replacingOccurrences(of: "pending", with: "denied"))
        MockURLProtocol.enqueue(status: 403, json: #"{"errors":[{"code":"STEP_UP_REQUIRED","message":"Re-authenticate."}]}"#)
        let client = makeClient(store: try signedIn())
        let auth = try await client.lookupDeviceAuthorization(userCode: " wdjb mjht ")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/device_authorizations/lookup")
        XCTAssertEqual(try body(0)["user_code"] as? String, "WDJB-MJHT")
        XCTAssertTrue(MockURLProtocol.recorded[0].value(forHTTPHeaderField: "Cookie")?.contains("jwt") ?? false)
        XCTAssertEqual(auth.client.name, "TV")
        XCTAssertTrue(auth.requiresStepUp)
        XCTAssertEqual(auth.scopes.first?.description, "Sign you in")
        let approved = try await client.approveDeviceAuthorization(auth)
        XCTAssertEqual(approved.status, "approved")
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/me/device_authorizations/da_1/approve")
        let denied = try await client.denyDeviceAuthorization(auth)
        XCTAssertEqual(denied.status, "denied")
        XCTAssertEqual(MockURLProtocol.recorded[2].url?.path, "/v1/client/me/device_authorizations/da_1/deny")
        do {
            _ = try await client.approveDeviceAuthorization(auth)
            XCTFail("expected a refusal")
        } catch let error as AtlasError {
            XCTAssertEqual(error.code, "STEP_UP_REQUIRED")
        }
        XCTAssertEqual(AtlasClient.formatUserCode("abc"), "abc")
        XCTAssertEqual(AtlasClient.userCodeFromURL(URL(string: "https://example.com/device?user_code=wdjbmjht")!), "WDJB-MJHT")
        XCTAssertNil(AtlasClient.userCodeFromURL(URL(string: "https://example.com/device")!))
    }

    func testDeviceApprovalNeedsASession() async {
        do {
            _ = try await makeClient().lookupDeviceAuthorization(userCode: "WDJB-MJHT")
            XCTFail("expected notSignedIn")
        } catch AtlasError.notSignedIn {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPasskeyPRFValues() {
        let prf = AtlasPasskeyPRF(salt: "my-app-key", second: "next")
        XCTAssertEqual(prf.first, Data("my-app-key".utf8))
        XCTAssertEqual(prf.second, Data("next".utf8))
        XCTAssertTrue(prf.perCredential.isEmpty)
        let result = AtlasPasskeyPRFResult(credentialID: Data([1]), isSupported: true, first: Data([2]), second: nil)
        XCTAssertEqual(result.first, Data([2]))
    }
}
