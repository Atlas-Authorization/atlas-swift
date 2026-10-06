import XCTest
@testable import Atlas

/// Flow-driver tests. The pure step mapping needs no network; the driver
/// transitions run against the mocked `URLProtocol`, so they pin the exact
/// endpoints, the retry-safe "attempt survives an error" contract, and that a
/// completion is exchanged for a persisted session — all device-free.
final class FlowTests: XCTestCase {
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

    private func attempt(status: String, strategies: [String]? = nil, ticket: String? = nil) -> SignInAttempt {
        SignInAttempt(
            id: "sia_1",
            status: status,
            supportedFirstFactors: strategies,
            createdSessionId: status == "complete" ? "sess_1" : nil,
            authorizationURL: nil,
            ticket: ticket
        )
    }

    // MARK: pure step mapping (no network)

    func testStepMappingCoversEveryStatus() {
        XCTAssertEqual(signInStep(attempt(status: "needs_identifier")), .collectIdentifier)
        XCTAssertEqual(
            signInStep(attempt(status: "needs_first_factor", strategies: ["password", "email_code"])),
            .collectFirstFactor(strategies: ["password", "email_code"])
        )
        XCTAssertEqual(signInStep(attempt(status: "needs_second_factor")), .collectSecondFactor)
        XCTAssertEqual(signInStep(attempt(status: "needs_mfa_enrollment")), .enrollSecondFactor)
        XCTAssertEqual(signInStep(attempt(status: "needs_email_verification")), .collectEmailCode)
        XCTAssertEqual(signInStep(attempt(status: "needs_captcha")), .collectCaptcha)
        XCTAssertEqual(signInStep(attempt(status: "needs_oauth_callback")), .awaitOAuth)
        XCTAssertEqual(signInStep(attempt(status: "needs_new_password")), .collectNewPassword)
        XCTAssertEqual(signInStep(attempt(status: "complete")), .done(sessionId: "sess_1"))
        XCTAssertEqual(signInStep(attempt(status: "abandoned")), .restart(reason: "abandoned"))
    }

    func testUnknownStatusMapsToUnknownNotABlankScreen() {
        XCTAssertEqual(signInStep(attempt(status: "needs_quantum_factor")), .unknown(status: "needs_quantum_factor"))
    }

    func testIsTerminal() {
        XCTAssertTrue(isTerminal(attempt(status: "complete")))
        XCTAssertTrue(isTerminal(attempt(status: "abandoned")))
        XCTAssertFalse(isTerminal(attempt(status: "needs_first_factor")))
    }

    // MARK: sign-in driver transitions

    func testPasswordSignInDrivesToDoneAndPersists() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_7","status":"needs_first_factor","supported_first_factors":["password"]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_7","status":"complete","created_session_id":"sess_7","ticket":"tk_7"}"#)
        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"object":"session","id":"sess_7","jwt":"jwt_7","expires_in":60}"#,
            headers: ["Set-Cookie": "__atlas_rt=rt_7; Path=/; HttpOnly"]
        )

        let store = InMemoryTokenStore()
        let flow = makeClient(store: store).signInFlow()

        let afterStart = try await flow.start(identifier: "a@b.com")
        XCTAssertEqual(afterStart, .collectFirstFactor(strategies: ["password"]))

        let afterPassword = try await flow.attemptPassword("hunter2")
        XCTAssertEqual(afterPassword, .done(sessionId: "sess_7"))

        // Exact endpoints + bodies.
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ins")
        XCTAssertEqual(try bodyString(0, "identifier"), "a@b.com")
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/sign_ins/sia_7/attempt_first_factor")
        XCTAssertEqual(try bodyString(1, "strategy"), "password")
        XCTAssertEqual(try bodyString(1, "password"), "hunter2")
        XCTAssertEqual(MockURLProtocol.recorded[2].url?.path, "/v1/client/tickets/exchange")

        // The completion was exchanged and persisted.
        let stored = try XCTUnwrap(try store.load())
        XCTAssertEqual(stored.token, "jwt_7")
        XCTAssertEqual(stored.refreshToken, "rt_7")
    }

    func testSecondFactorPathThenComplete() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_2","status":"needs_first_factor","supported_first_factors":["password"]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_2","status":"needs_second_factor"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_2","status":"complete","created_session_id":"sess_2","ticket":"tk_2"}"#)
        MockURLProtocol.enqueue(
            status: 200,
            json: #"{"id":"sess_2","jwt":"jwt_2","expires_in":60}"#,
            headers: ["Set-Cookie": "__atlas_rt=rt_2; Path=/; HttpOnly"]
        )

        let store = InMemoryTokenStore()
        let flow = makeClient(store: store).signInFlow()
        _ = try await flow.start(identifier: "a@b.com")
        let needs2fa = try await flow.attemptPassword("pw")
        XCTAssertEqual(needs2fa, .collectSecondFactor)

        let done = try await flow.attemptSecondFactor(code: "123456")
        XCTAssertEqual(done, .done(sessionId: "sess_2"))
        XCTAssertEqual(MockURLProtocol.recorded[2].url?.path, "/v1/client/sign_ins/sia_2/attempt_second_factor")
        XCTAssertEqual(try bodyString(2, "code"), "123456")
        XCTAssertEqual(try store.load()?.token, "jwt_2")
    }

    func testWrongPasswordLeavesAttemptForRetry() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_3","status":"needs_first_factor","supported_first_factors":["password"]}"#)
        MockURLProtocol.enqueue(status: 422, json: #"{"errors":[{"code":"form_password_incorrect","message":"Incorrect password.","param":"password"}]}"#)

        let flow = makeClient().signInFlow()
        _ = try await flow.start(identifier: "a@b.com")
        do {
            _ = try await flow.attemptPassword("wrong")
            XCTFail("expected AtlasError")
        } catch let error as AtlasError {
            XCTAssertEqual(error.code, "form_password_incorrect")
        }
        // The attempt survived; the step is still the first-factor prompt.
        let step = await flow.step
        XCTAssertEqual(step, .collectFirstFactor(strategies: ["password"]))
    }

    func testEmailCodeFirstFactor() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_e","status":"needs_first_factor","supported_first_factors":["email_code"]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_e","status":"needs_first_factor","strategy":"email_code","poll_secret":"ps_1"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_e","status":"complete","created_session_id":"sess_e","ticket":"tk_e"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_e","jwt":"jwt_e","expires_in":60}"#, headers: ["Set-Cookie": "__atlas_rt=rt_e; Path=/"])

        let flow = makeClient().signInFlow()
        _ = try await flow.start(identifier: "a@b.com")
        _ = try await flow.prepareEmailCode()
        let done = try await flow.attemptEmailCode("000111")
        XCTAssertEqual(done, .done(sessionId: "sess_e"))
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/sign_ins/sia_e/prepare_first_factor")
        XCTAssertEqual(try bodyString(1, "strategy"), "email_code")
        XCTAssertEqual(try bodyString(2, "code"), "000111")
    }

    func testMfaEnrollmentFlow() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_m","status":"needs_first_factor","supported_first_factors":["password"]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_m","status":"needs_mfa_enrollment"}"#)
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"mfa_enrollment","factor_id":"fac_1","secret":"BASE32SECRET","uri":"otpauth://totp/Atlas:a@b.com?secret=BASE32SECRET"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_m","status":"complete","created_session_id":"sess_m","ticket":"tk_m","backup_codes":["aaaa-bbbb","cccc-dddd"]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_m","jwt":"jwt_m","expires_in":60}"#, headers: ["Set-Cookie": "__atlas_rt=rt_m; Path=/"])

        let flow = makeClient().signInFlow()
        _ = try await flow.start(identifier: "a@b.com")
        let needsEnroll = try await flow.attemptPassword("pw")
        XCTAssertEqual(needsEnroll, .enrollSecondFactor)

        let enrollment = try await flow.prepareMfaEnrollment()
        XCTAssertEqual(enrollment.factorId, "fac_1")
        XCTAssertEqual(enrollment.secret, "BASE32SECRET")
        XCTAssertEqual(MockURLProtocol.recorded[2].url?.path, "/v1/client/sign_ins/sia_m/prepare_mfa_enrollment")

        let done = try await flow.attemptMfaEnrollment(factorId: enrollment.factorId, codes: ["123456"])
        XCTAssertEqual(done, .done(sessionId: "sess_m"))
        let backup = await flow.lastBackupCodes
        XCTAssertEqual(backup, ["aaaa-bbbb", "cccc-dddd"])
        // The codes array made it into the body as an array.
        let enrollBody = try JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[3]) as? [String: Any]
        XCTAssertEqual(enrollBody?["codes"] as? [String], ["123456"])
        XCTAssertEqual(enrollBody?["factor_id"] as? String, "fac_1")
    }

    // MARK: sign-up driver

    func testSignUpFlow() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"sign_up_attempt","id":"sua_1","status":"needs_email_verification"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"sign_up_attempt","id":"sua_1","status":"complete","created_session_id":"sess_s","ticket":"tk_s"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_s","jwt":"jwt_s","expires_in":60}"#, headers: ["Set-Cookie": "__atlas_rt=rt_s; Path=/"])

        let store = InMemoryTokenStore()
        let flow = makeClient(store: store).signUpFlow()
        let afterStart = try await flow.start(email: "new@b.com", password: "hunter2", consent: true)
        XCTAssertEqual(afterStart, .collectEmailCode)
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ups")
        XCTAssertEqual(try bodyString(0, "email"), "new@b.com")
        let body0 = try JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[0]) as? [String: Any]
        XCTAssertEqual(body0?["consent"] as? Bool, true)

        let done = try await flow.attemptVerification(code: "424242")
        XCTAssertEqual(done, .done(sessionId: "sess_s"))
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/sign_ups/sua_1/attempt_verification")
        XCTAssertEqual(try store.load()?.token, "jwt_s")
    }

    // MARK: password-reset driver

    func testPasswordResetFlow() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"pr_1","status":"needs_email_verification"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"pr_1","status":"needs_new_password"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"pr_1","status":"complete","ticket":"tk_r"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_r","jwt":"jwt_r","expires_in":60}"#, headers: ["Set-Cookie": "__atlas_rt=rt_r; Path=/"])

        let store = InMemoryTokenStore()
        let flow = makeClient(store: store).passwordResetFlow()
        let step1 = try await flow.start(email: "a@b.com")
        XCTAssertEqual(step1, .collectEmailCode)
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/password_resets")
        XCTAssertEqual(try bodyString(0, "email_address"), "a@b.com")

        let step2 = try await flow.attemptVerification(code: "111222")
        XCTAssertEqual(step2, .collectNewPassword)
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/password_resets/pr_1/attempt_verification")

        let step3 = try await flow.setNewPassword("newpass!")
        XCTAssertEqual(step3, .done)
        XCTAssertEqual(MockURLProtocol.recorded[2].url?.path, "/v1/client/password_resets/pr_1/set_new_password")
        XCTAssertEqual(try store.load()?.token, "jwt_r")
    }

    // MARK: helpers

    private func bodyString(_ index: Int, _ key: String) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[index]) as? [String: Any]
        return object?[key] as? String
    }
}
