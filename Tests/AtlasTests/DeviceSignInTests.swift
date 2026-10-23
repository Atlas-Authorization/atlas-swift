import XCTest
@testable import Atlas

/// The RFC 8628 device sign-in client: the device_authorization request, the
/// polling state machine (authorization_pending, slow_down, network backoff,
/// expiry, denial), the session exchange, and the error mapping — against the
/// shared `MockURLProtocol` queue with a fake clock, so no test really waits.
final class DeviceSignInTests: XCTestCase {
    private let clientId = "oc_tv_app"

    private let userJSON = #"{"id":"user_1","first_name":"Ada","last_name":"Lovelace"}"#
    private let pending = #"{"error":"authorization_pending","error_description":"The authorization request is still pending."}"#
    private let slowDown = #"{"error":"slow_down","error_description":"Polling too frequently; slow down."}"#
    private let approved = #"{"access_token":"at_device","token_type":"Bearer","expires_in":3600,"refresh_token":"ort_1","scope":"openid"}"#
    private let sessionExchange = #"{"access_token":"sess_jwt","issued_token_type":"urn:atlas:token-type:session","token_type":"Bearer","expires_in":60,"refresh_token":"rt_sess","session_id":"sess_42"}"#

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    /// A clock that only moves when the client "sleeps", recording each sleep.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_800_000_000)
        private(set) var sleeps: [TimeInterval] = []

        var date: Date { lock.lock(); defer { lock.unlock() }; return now }

        func sleep(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            sleeps.append(seconds)
            now = now.addingTimeInterval(seconds)
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            now = now.addingTimeInterval(seconds)
        }
    }

    private func makeClient(store: TokenStore = InMemoryTokenStore(), clock: FakeClock = FakeClock(), oauthClientId: String? = "oc_tv_app") -> AtlasClient {
        let client = AtlasClient(
            publishableKey: "pk_test_123",
            frontendApi: "clerk.example.com",
            tokenStore: store,
            urlSession: MockURLProtocol.makeSession(),
            oauthClientId: oauthClientId
        )
        client.deviceFlowClock = { clock.date }
        client.deviceFlowSleep = { seconds in
            try Task.checkCancellation()
            clock.sleep(seconds)
        }
        return client
    }

    private func authorization(issuedAt: Date, expiresIn: Int = 600, interval: Int = 5) -> AtlasDeviceAuthorization {
        AtlasDeviceAuthorization(
            clientId: clientId,
            deviceCode: "dc_secret",
            userCode: "WDJB-MJHT",
            verificationURI: URL(string: "https://clerk.example.com/oauth2/device")!,
            verificationURIComplete: URL(string: "https://clerk.example.com/oauth2/device?user_code=WDJB-MJHT")!,
            expiresIn: expiresIn,
            interval: interval,
            issuedAt: issuedAt
        )
    }

    private func form(_ index: Int) -> [String: String] {
        let body = String(decoding: MockURLProtocol.recordedBodies[index], as: UTF8.self)
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }

    // MARK: start

    func testStartPostsTheDeviceAuthorizationFormAndParsesTheCodes() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"""
        {"device_code":"dc_secret","user_code":"WDJB-MJHT","verification_uri":"https://clerk.example.com/oauth2/device",
         "verification_uri_complete":"https://clerk.example.com/oauth2/device?user_code=WDJB-MJHT","expires_in":600,"interval":5}
        """#)
        let clock = FakeClock()
        let auth = try await makeClient(clock: clock).startDeviceSignIn(scopes: ["openid", "offline_access"])

        let request = MockURLProtocol.recorded[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://clerk.example.com/oauth2/device_authorization")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-publishable-key"), "pk_test_123")
        XCTAssertEqual(form(0), ["client_id": clientId, "scope": "openid offline_access"])

        XCTAssertEqual(auth.clientId, clientId)
        XCTAssertEqual(auth.deviceCode, "dc_secret")
        XCTAssertEqual(auth.userCode, "WDJB-MJHT")
        XCTAssertEqual(auth.verificationURI.absoluteString, "https://clerk.example.com/oauth2/device")
        XCTAssertEqual(auth.verificationURIComplete?.absoluteString, "https://clerk.example.com/oauth2/device?user_code=WDJB-MJHT")
        XCTAssertEqual(auth.qrCodeURL, auth.verificationURIComplete)
        XCTAssertEqual(auth.displayVerificationURI, "clerk.example.com/oauth2/device")
        XCTAssertEqual(auth.expiresIn, 600)
        XCTAssertEqual(auth.interval, 5)
        XCTAssertEqual(auth.issuedAt, clock.date)
        XCTAssertEqual(auth.expiresAt, clock.date.addingTimeInterval(600))
        XCTAssertEqual(auth.secondsRemaining(at: clock.date.addingTimeInterval(599.2)), 1)
        XCTAssertEqual(auth.secondsRemaining(at: clock.date.addingTimeInterval(700)), 0)
    }

    func testStartWithoutScopesAsksForTheClientsSetAndDefaultsTheInterval() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"https://x.example/oauth2/device","expires_in":300}"#)
        let auth = try await makeClient().startDeviceSignIn(clientId: "oc_explicit")
        XCTAssertEqual(form(0), ["client_id": "oc_explicit"])
        XCTAssertEqual(auth.clientId, "oc_explicit")
        XCTAssertEqual(auth.interval, 5, "RFC 8628 §3.2: no interval means 5 seconds")
        XCTAssertNil(auth.verificationURIComplete)
        XCTAssertEqual(auth.qrCodeURL.absoluteString, "https://x.example/oauth2/device")
    }

    func testStartWithoutAClientIdFailsBeforeAnyRequest() async {
        do {
            _ = try await makeClient(oauthClientId: nil).startDeviceSignIn()
            XCTFail("expected invalid_client")
        } catch let error as AtlasError {
            XCTAssertEqual(error.code, "invalid_client")
            XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStartMapsTheOAuthErrorBody() async {
        MockURLProtocol.enqueue(status: 400, json: #"{"error":"unauthorized_client","error_description":"This client is not permitted the device_code grant."}"#)
        do {
            _ = try await makeClient().startDeviceSignIn()
            XCTFail("expected an error")
        } catch let error as AtlasError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.code, "unauthorized_client")
            XCTAssertEqual(error.message, "This client is not permitted the device_code grant.")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: wait — success

    func testWaitPollsUntilApprovedThenEstablishesTheSession() async throws {
        let clock = FakeClock()
        let store = InMemoryTokenStore()
        let client = makeClient(store: store, clock: clock)
        MockURLProtocol.enqueue(status: 400, json: pending)
        MockURLProtocol.enqueue(status: 400, json: pending)
        MockURLProtocol.enqueue(status: 200, json: approved)
        MockURLProtocol.enqueue(status: 200, json: sessionExchange)
        MockURLProtocol.enqueue(status: 200, json: userJSON)

        let user = try await client.waitForDeviceSignIn(authorization(issuedAt: clock.date), deviceName: "Living room TV")

        XCTAssertEqual(user.id, "user_1")
        XCTAssertEqual(clock.sleeps, [5, 5, 5], "waits one interval before every poll")
        XCTAssertEqual(MockURLProtocol.recorded.count, 5)

        for i in 0..<3 {
            XCTAssertEqual(MockURLProtocol.recorded[i].url?.path, "/oauth2/token")
            XCTAssertEqual(form(i), [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": "dc_secret",
                "client_id": clientId,
            ])
        }
        XCTAssertEqual(form(3), [
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "client_id": clientId,
            "subject_token": "at_device",
            "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "requested_token_type": "urn:atlas:token-type:session",
            "device_name": "Living room TV",
        ])
        XCTAssertEqual(MockURLProtocol.recorded[4].url?.path, "/v1/client/me")
        XCTAssertEqual(MockURLProtocol.recorded[4].value(forHTTPHeaderField: "Cookie"), "__session=sess_jwt; __atlas_rt=rt_sess")

        let saved = try XCTUnwrap(try store.load())
        XCTAssertEqual(saved, AtlasSession(sessionId: "sess_42", token: "sess_jwt", refreshToken: "rt_sess"))
        XCTAssertTrue(client.hasSession())
    }

    func testDefaultDeviceNameIsThePlatform() async throws {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        MockURLProtocol.enqueue(status: 200, json: approved)
        MockURLProtocol.enqueue(status: 200, json: sessionExchange)
        MockURLProtocol.enqueue(status: 200, json: userJSON)
        try await client.waitForDeviceSignIn(authorization(issuedAt: clock.date))
        XCTAssertEqual(form(1)["device_name"], AtlasClient.platformDeviceName)
    }

    // MARK: wait — pacing

    func testSlowDownAddsFiveSecondsForTheRestOfTheWait() async throws {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        MockURLProtocol.enqueue(status: 400, json: pending)
        MockURLProtocol.enqueue(status: 400, json: slowDown)
        MockURLProtocol.enqueue(status: 400, json: pending)
        MockURLProtocol.enqueue(status: 400, json: slowDown)
        MockURLProtocol.enqueue(status: 200, json: approved)
        MockURLProtocol.enqueue(status: 200, json: sessionExchange)
        MockURLProtocol.enqueue(status: 200, json: userJSON)

        try await client.waitForDeviceSignIn(authorization(issuedAt: clock.date))
        XCTAssertEqual(clock.sleeps, [5, 5, 10, 10, 15])
    }

    func testANetworkFailureBacksOffAndKeepsWaiting() async throws {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        MockURLProtocol.enqueueFailure()
        MockURLProtocol.enqueueFailure(.timedOut)
        MockURLProtocol.enqueue(status: 200, json: approved)
        MockURLProtocol.enqueue(status: 200, json: sessionExchange)
        MockURLProtocol.enqueue(status: 200, json: userJSON)

        let user = try await client.waitForDeviceSignIn(authorization(issuedAt: clock.date))
        XCTAssertEqual(user.id, "user_1")
        XCTAssertEqual(clock.sleeps, [5, 10, 20])
    }

    func testBackoffIsCappedAtSixtySeconds() async throws {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        for _ in 0..<5 { MockURLProtocol.enqueueFailure() }
        MockURLProtocol.enqueue(status: 200, json: approved)
        MockURLProtocol.enqueue(status: 200, json: sessionExchange)
        MockURLProtocol.enqueue(status: 200, json: userJSON)

        try await client.waitForDeviceSignIn(authorization(issuedAt: clock.date))
        XCTAssertEqual(clock.sleeps, [5, 10, 20, 40, 60, 60])
    }

    // MARK: wait — expiry

    func testExpiryEndsTheWaitWithoutPollingADeadCode() async {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        MockURLProtocol.enqueue(status: 400, json: pending)
        MockURLProtocol.enqueue(status: 400, json: pending)

        do {
            try await client.waitForDeviceSignIn(authorization(issuedAt: clock.date, expiresIn: 12))
            XCTFail("expected expiry")
        } catch let error as AtlasError {
            XCTAssertTrue(error.isDeviceCodeExpired)
            XCTAssertEqual(error.code, "expired_token")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(clock.sleeps, [5, 5, 2], "the last sleep is capped at the time left")
        XCTAssertEqual(MockURLProtocol.recorded.count, 2, "no poll after the deadline")
    }

    func testAnAlreadyExpiredCodeFailsImmediately() async {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        let auth = authorization(issuedAt: clock.date, expiresIn: 600)
        clock.advance(601)
        do {
            try await client.waitForDeviceSignIn(auth)
            XCTFail("expected expiry")
        } catch let error as AtlasError {
            XCTAssertTrue(error.isDeviceCodeExpired)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    func testServerSideExpiryIsTyped() async {
        let clock = FakeClock()
        MockURLProtocol.enqueue(status: 400, json: #"{"error":"expired_token","error_description":"The device_code has expired."}"#)
        do {
            try await makeClient(clock: clock).waitForDeviceSignIn(authorization(issuedAt: clock.date))
            XCTFail("expected expiry")
        } catch let error as AtlasError {
            XCTAssertTrue(error.isDeviceCodeExpired)
            XCTAssertFalse(error.isDeviceSignInDenied)
            XCTAssertEqual(error.message, "The device_code has expired.")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: wait — refusals

    func testDenialIsTypedAndStopsPolling() async {
        let clock = FakeClock()
        let store = InMemoryTokenStore()
        MockURLProtocol.enqueue(status: 400, json: pending)
        MockURLProtocol.enqueue(status: 400, json: #"{"error":"access_denied","error_description":"The user denied the request."}"#)
        do {
            try await makeClient(store: store, clock: clock).waitForDeviceSignIn(authorization(issuedAt: clock.date))
            XCTFail("expected denial")
        } catch let error as AtlasError {
            XCTAssertTrue(error.isDeviceSignInDenied)
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.message, "The user denied the request.")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(MockURLProtocol.recorded.count, 2)
        XCTAssertNil(try store.load())
    }

    func testInvalidGrantSurfacesTheServerError() async {
        let clock = FakeClock()
        MockURLProtocol.enqueue(status: 400, json: #"{"error":"invalid_grant","error_description":"The device_code is invalid."}"#)
        do {
            try await makeClient(clock: clock).waitForDeviceSignIn(authorization(issuedAt: clock.date))
            XCTFail("expected invalid_grant")
        } catch let error as AtlasError {
            XCTAssertEqual(error.code, "invalid_grant")
            XCTAssertFalse(error.isDeviceCodeExpired)
            XCTAssertFalse(error.isDeviceSignInDenied)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testARefusedSessionExchangeLeavesNoSession() async {
        let clock = FakeClock()
        let store = InMemoryTokenStore()
        MockURLProtocol.enqueue(status: 200, json: approved)
        MockURLProtocol.enqueue(status: 400, json: #"{"error":"invalid_grant","error_description":"No active, session-eligible grant backs this token."}"#)
        do {
            try await makeClient(store: store, clock: clock).waitForDeviceSignIn(authorization(issuedAt: clock.date))
            XCTFail("expected the exchange to fail")
        } catch let error as AtlasError {
            XCTAssertEqual(error.code, "invalid_grant")
            XCTAssertEqual(error.message, "No active, session-eligible grant backs this token.")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertNil(try store.load())
    }

    func testATokenResponseWithoutAnAccessTokenIsADecodingError() async {
        let clock = FakeClock()
        MockURLProtocol.enqueue(status: 200, json: #"{"token_type":"Bearer"}"#)
        do {
            try await makeClient(clock: clock).waitForDeviceSignIn(authorization(issuedAt: clock.date))
            XCTFail("expected a decoding error")
        } catch AtlasError.decoding {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testANonOAuthErrorBodyFallsBackToTheEnvelope() {
        let error = parseOAuthError(status: 503, data: Data(#"{"errors":[{"code":"RATE_LIMITED","message":"Slow down."}]}"#.utf8))
        XCTAssertEqual(error.code, "RATE_LIMITED")
        XCTAssertEqual(parseOAuthError(status: 502, data: Data("<html>".utf8)).code, "unexpected")
        XCTAssertEqual(parseOAuthError(status: 400, data: Data(#"{"error":"access_denied"}"#.utf8)).message, "The sign-in was denied.")
    }

    // MARK: cancellation

    func testCancellingTheTaskStopsTheWait() async {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        client.deviceFlowSleep = { _ in try await Task.sleep(nanoseconds: 10_000_000_000) }
        let task = Task { try await client.waitForDeviceSignIn(self.authorization(issuedAt: clock.date)) }
        task.cancel()
        let result = await task.result
        switch result {
        case .success: XCTFail("expected cancellation")
        case let .failure(error): XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    // MARK: the SwiftUI model

    @available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
    @MainActor
    func testModelSignsInAndRefreshesTheSession() async {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        MockURLProtocol.enqueue(status: 200, json: #"{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"https://clerk.example.com/oauth2/device","verification_uri_complete":"https://clerk.example.com/oauth2/device?user_code=AAAA-BBBB","expires_in":600,"interval":5}"#)
        MockURLProtocol.enqueue(status: 200, json: approved)
        MockURLProtocol.enqueue(status: 200, json: sessionExchange)
        MockURLProtocol.enqueue(status: 200, json: userJSON) // waitForDeviceSignIn's /me
        MockURLProtocol.enqueue(status: 200, json: userJSON) // the session's reload

        let session = AtlasAuthSession(client: client)
        let model = DeviceSignInModel(session: session)
        XCTAssertTrue(model.isAvailable)
        await model.run()

        XCTAssertEqual(model.phase, .completed)
        XCTAssertTrue(model.completed)
        XCTAssertEqual(session.user?.id, "user_1")
    }

    @available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
    @MainActor
    func testModelRenewsAnExpiredCodeThenGivesUp() async {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        let start = #"{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"https://clerk.example.com/oauth2/device","expires_in":600,"interval":5}"#
        let expired = #"{"error":"expired_token","error_description":"The device_code has expired."}"#
        for _ in 0...DeviceSignInModel.automaticRenewals {
            MockURLProtocol.enqueue(status: 200, json: start)
            MockURLProtocol.enqueue(status: 400, json: expired)
        }

        let model = DeviceSignInModel(session: AtlasAuthSession(client: client))
        await model.run()

        XCTAssertEqual(model.phase, .expired)
        XCTAssertFalse(model.completed)
        let starts = MockURLProtocol.recorded.filter { $0.url?.path == "/oauth2/device_authorization" }
        XCTAssertEqual(starts.count, DeviceSignInModel.automaticRenewals + 1)
        XCTAssertNotNil(model.qrCode, "each code gets a QR code")
    }

    @available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
    @MainActor
    func testModelReportsADenial() async {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        MockURLProtocol.enqueue(status: 200, json: #"{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"https://clerk.example.com/oauth2/device","expires_in":600,"interval":5}"#)
        MockURLProtocol.enqueue(status: 400, json: #"{"error":"access_denied","error_description":"The user denied the request."}"#)
        let model = DeviceSignInModel(session: AtlasAuthSession(client: client))
        await model.run()
        XCTAssertEqual(model.phase, .denied)
    }

    @available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
    @MainActor
    func testModelIsUnavailableWithoutAClientId() async {
        let model = DeviceSignInModel(session: AtlasAuthSession(client: makeClient(oauthClientId: nil)))
        XCTAssertFalse(model.isAvailable)
        await model.run()
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
        XCTAssertTrue(DeviceSignInModel(session: AtlasAuthSession(client: makeClient(oauthClientId: nil)), clientId: "oc_x").isAvailable)
    }
}
