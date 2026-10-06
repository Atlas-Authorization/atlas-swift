import XCTest
@testable import Atlas

/// Native id_token (Sign in with Apple / Google One-Tap) tests — the pure body
/// mapping and the exchange, both device-free.
final class IdTokenTests: XCTestCase {
    let pk = "pk_test_123"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeClient(store: TokenStore = InMemoryTokenStore()) -> AtlasClient {
        AtlasClient(
            publishableKey: pk,
            frontendApi: "clerk.example.com",
            tokenStore: store,
            urlSession: MockURLProtocol.makeSession()
        )
    }

    // MARK: pure mapping

    func testIdTokenBodyOmitsNonceWhenAbsent() {
        let body = idTokenSignInBody(provider: "apple", idToken: "jwt.apple", nonce: nil)
        XCTAssertEqual(body["provider"] as? String, "apple")
        XCTAssertEqual(body["id_token"] as? String, "jwt.apple")
        XCTAssertNil(body["nonce"])
    }

    func testIdTokenBodyIncludesNonceWhenPresent() {
        let body = idTokenSignInBody(provider: "google", idToken: "jwt.google", nonce: "n_123")
        XCTAssertEqual(body["nonce"] as? String, "n_123")
    }

    func testAppleIdentityTokenDecodesUtf8Bytes() {
        XCTAssertEqual(appleIdentityToken(from: Data("header.payload.sig".utf8)), "header.payload.sig")
        XCTAssertNil(appleIdentityToken(from: nil))
        XCTAssertNil(appleIdentityToken(from: Data()))
    }

    // MARK: exchange

    func testIdTokenCompleteExchangesAndReturnsUser() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"sign_in_attempt","id":"sia_i","status":"complete","ticket":"tk_i"}"#)
        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"id":"sess_i","jwt":"jwt_i","expires_in":60}"#,
            headers: ["Set-Cookie": "__atlas_rt=rt_i; Path=/"]
        )
        MockURLProtocol.enqueue(status: 200, json: Self.userJSON)

        let store = InMemoryTokenStore()
        let result = try await makeClient(store: store).signInWithIdToken(
            provider: "apple", idToken: "jwt.apple", nonce: "n_1"
        )
        guard case let .complete(user) = result else {
            return XCTFail("expected .complete, got \(result)")
        }
        XCTAssertEqual(user.id, "user_1")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ins/id_token")
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[0]) as? [String: Any]
        XCTAssertEqual(body?["provider"] as? String, "apple")
        XCTAssertEqual(body?["id_token"] as? String, "jwt.apple")
        XCTAssertEqual(body?["nonce"] as? String, "n_1")
        XCTAssertEqual(try store.load()?.token, "jwt_i")
    }

    func testIdTokenNeedsSecondFactorHandsBackAFlow() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"sign_in_attempt","id":"sia_j","status":"needs_second_factor"}"#)

        let result = try await makeClient().signInWithIdToken(provider: "google", idToken: "jwt.g")
        guard case let .needsNextStep(flow) = result else {
            return XCTFail("expected .needsNextStep, got \(result)")
        }
        let step = await flow.step
        XCTAssertEqual(step, .collectSecondFactor)
        let id = await flow.attemptId
        XCTAssertEqual(id, "sia_j")
    }

    func testMintNativeNonce() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"native_nonce","nonce":"n_minted"}"#)
        let nonce = try await makeClient().mintNativeNonce(provider: "google")
        XCTAssertEqual(nonce, "n_minted")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ins/id_token/nonce")
    }

    static let userJSON = #"{"object":"user","id":"user_1","email_addresses":[],"external_accounts":[],"passkeys":[]}"#
}
