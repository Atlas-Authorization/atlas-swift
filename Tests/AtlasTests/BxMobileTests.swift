import XCTest
@testable import Atlas

/// Device id on account-creating starts, captcha on passkey sign-in, passkey-only
/// sign-up, SMS MFA enrolment + the TOTP QR image, and the organization audit log.
final class BxMobileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeClient(store: TokenStore = InMemoryTokenStore()) -> AtlasClient {
        let client = AtlasClient(
            publishableKey: "pk_test_123",
            frontendApi: "clerk.example.com",
            tokenStore: store,
            urlSession: MockURLProtocol.makeSession()
        )
        client.deviceIdProvider = { "d_test" }
        return client
    }

    private func body(_ index: Int) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[index]) as? [String: Any] ?? [:]
    }

    func testDeviceIdRidesOnAccountCreatingStartsOnly() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sua_1","status":"needs_email_verification"}"#)
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["password"]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_o","status":"needs_first_factor","authorization_url":"https://idp.example/auth"}"#)
        let client = makeClient()
        _ = try await client.signUpFlow().start(email: "a@b.com", password: "pw")
        XCTAssertEqual(try body(0)["device_id"] as? String, "d_test")
        _ = try await client.signInFlow().start(identifier: "a@b.com")
        XCTAssertNil(try body(1)["device_id"], "password sign-in never carries the device id")
        _ = try await client.oauthAuthorizeURL(provider: "google", redirectURI: "app://cb")
        XCTAssertEqual(try body(2)["device_id"] as? String, "d_test")

        XCTAssertNil(DeviceId.stamp(nil, path: "/v1/client/sign_ups", method: "POST", id: { "x" }))
        let kept = DeviceId.stamp(["device_id": "mine"], path: "/v1/client/sign_ups", method: "POST", id: { "x" })
        XCTAssertEqual(kept?["device_id"] as? String, "mine")
        XCTAssertTrue(DeviceId.routes.contains("/v1/client/sign_ins/id_token"))
        let defaults = UserDefaults(suiteName: "atlas-bx-test")!
        defaults.removeObject(forKey: DeviceId.defaultsKey)
        let first = DeviceId.current(defaults)
        XCTAssertTrue(first.hasPrefix("d_"))
        XCTAssertEqual(DeviceId.current(defaults), first, "the id is stable across calls")
    }

    func testCaptchaRequiredIsTyped() {
        let error = AtlasError.api(status: 400, errors: [AtlasErrorItem(code: "CAPTCHA_REQUIRED", message: "Solve the captcha.")])
        XCTAssertEqual(error.knownCode, .captchaRequired)
        XCTAssertTrue(error.isCaptchaRequired)
        XCTAssertEqual(passkeySignInBeginBody(captchaToken: "tok"), ["captcha_token": "tok"])
        XCTAssertEqual(passkeySignInBeginBody(captchaToken: nil), [:])
    }

    func testSmsMfaEnrollmentAndTotpQr() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_m","status":"needs_mfa_enrollment"}"#)
        MockURLProtocol.enqueue(status: 201, json: #"{"factor_id":"fac_s","strategy":"phone_code","phone":"+1*******0123"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_m","status":"complete","created_session_id":"sess_m","ticket":"tk_m","backup_codes":["aaaa"]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_m","jwt":"jwt_m","expires_in":60}"#, headers: ["Set-Cookie": "__atlas_rt=rt_m; Path=/"])
        let flow = makeClient().signInFlow()
        _ = try await flow.start(identifier: "a@b.com")
        let enrollment = try await flow.prepareSmsMfaEnrollment(phone: "+14155550123")
        XCTAssertEqual(try body(1)["strategy"] as? String, "phone_code")
        XCTAssertEqual(try body(1)["phone"] as? String, "+14155550123")
        XCTAssertEqual(enrollment.strategy, "phone_code")
        XCTAssertEqual(enrollment.phone, "+1*******0123")
        XCTAssertEqual(enrollment.secret, "")
        let done = try await flow.attemptMfaEnrollment(factorId: enrollment.factorId, code: "123456")
        XCTAssertEqual(done, .done(sessionId: "sess_m"))
        XCTAssertEqual(try body(2)["code"] as? String, "123456")
        XCTAssertNil(try body(2)["codes"])

        let totp = try JSONDecoder().decode(MfaEnrollment.self, from: Data(#"{"factor_id":"f","secret":"S","uri":"otpauth://x","qr_code":"data:image/gif;base64,R0lGOD=="}"#.utf8))
        XCTAssertEqual(totp.strategy, "totp")
        XCTAssertEqual(totp.qrCode, "data:image/gif;base64,R0lGOD==")
        XCTAssertNotNil(totp.qrImageData)
        let unsafe = try JSONDecoder().decode(MfaEnrollment.self, from: Data(#"{"factor_id":"f","qr_code":"javascript:alert(1)"}"#.utf8))
        XCTAssertNil(unsafe.qrCode)
    }

    func testPasskeySignUpFlowStartsAndKeepsThePollSecret() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"sign_up_attempt","id":"sua_p","status":"needs_first_factor","supported_first_factors":["passkey"],"poll_secret":"ps_1"}"#)
        let flow = PasskeySignUpFlow(client: makeClient())
        _ = try await flow.start(email: "a@b.com", username: "ada", captchaToken: "cap")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ups/passkey")
        XCTAssertEqual(try body(0)["email"] as? String, "a@b.com")
        XCTAssertEqual(try body(0)["captcha_token"] as? String, "cap")
        let waiting = await flow.awaitingPasskey
        XCTAssertTrue(waiting)
        let context = try await flow.passkeyContext()
        XCTAssertEqual(context.0, "sua_p")
        XCTAssertEqual(context.1, "ps_1")
        let finish = signUpPasskeyFinishBody(
            pollSecret: "ps_1", challenge: "ch",
            result: PasskeyRegistrationResult(attestationObject: Data([1]), clientDataJSON: Data([2])), name: nil
        )
        XCTAssertEqual(finish["poll_secret"], "ps_1")
        XCTAssertEqual(finish["challenge"], "ch")
        XCTAssertNotNil(finish["attestation_object"])
    }

    func testOrganizationAuditLog() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"list","data":[{"object":"audit_log","id":"al_1","action":"member.added","actor":{"type":"user","id":"u_1"},"target":{"type":"user","id":"u_2"},"organization_id":"org_1","ip":null,"user_agent":null,"metadata":{},"created_at":1}],"has_more":true,"next_cursor":"al_1"}"#)
        let store = InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt"))
        let page = try await makeClient(store: store).organizationAuditLog(organizationId: "org_1", limit: 10, action: "member.")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/organizations/org_1/audit_logs")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.query, "limit=10&action=member.")
        XCTAssertEqual(page.data.first?.action, "member.added")
        XCTAssertEqual(page.nextCursor, "al_1")
        XCTAssertTrue(page.hasMore)
    }
}
