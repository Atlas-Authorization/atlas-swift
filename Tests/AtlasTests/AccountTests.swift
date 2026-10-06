import XCTest
@testable import Atlas

/// Organizations / session-listing / `/me`-mutation tests. They pin the exact
/// endpoint + method + body for each typed method, the authenticated-cookie
/// presentation, and the response → model mapping — all device-free.
final class AccountTests: XCTestCase {
    let pk = "pk_test_123"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func signedInClient() -> (AtlasClient, InMemoryTokenStore) {
        let store = InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt"))
        let client = AtlasClient(
            publishableKey: pk,
            frontendApi: "clerk.example.com",
            tokenStore: store,
            urlSession: MockURLProtocol.makeSession()
        )
        return (client, store)
    }

    private func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[index]) as? [String: Any])
    }

    // MARK: organizations

    func testOrganizationsDecodeMembershipList() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"""
        {"object":"list","data":[
          {"object":"organization_membership","role":"admin","organization":{"object":"organization","id":"org_1","name":"Acme","slug":"acme","image_url":null,"public_metadata":{"tier":"pro"}}}
        ]}
        """#)
        let (client, _) = signedInClient()
        let memberships = try await client.organizations()
        XCTAssertEqual(memberships.count, 1)
        XCTAssertEqual(memberships.first?.role, "admin")
        XCTAssertEqual(memberships.first?.organization.name, "Acme")
        XCTAssertEqual(memberships.first?.organization.publicMetadata?["tier"]?.stringValue, "pro")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/organizations")
        // Authenticated: the session + refresh cookie were presented.
        let cookie = MockURLProtocol.recorded[0].value(forHTTPHeaderField: "Cookie")
        XCTAssertTrue(cookie?.contains("__session=jwt") == true)
        XCTAssertTrue(cookie?.contains("__atlas_rt=rt") == true)
    }

    func testCreateOrganizationBody() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"organization","id":"org_2","name":"Beta","slug":"beta"}"#)
        let (client, _) = signedInClient()
        let org = try await client.createOrganization(name: "Beta", slug: "beta")
        XCTAssertEqual(org.id, "org_2")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/organizations")
        XCTAssertEqual(try body(0)["name"] as? String, "Beta")
        XCTAssertEqual(try body(0)["slug"] as? String, "beta")
    }

    func testSetActiveOrganizationPersistsRotatedJwt() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"session","id":"sess_1","jwt":"jwt_rotated","expires_in":60,"last_active_organization_id":"org_1"}"#)
        let (client, store) = signedInClient()
        let active = try await client.setActiveOrganization("org_1")
        XCTAssertEqual(active, "org_1")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sessions/sess_1/touch")
        XCTAssertEqual(try body(0)["active_organization_id"] as? String, "org_1")
        // The new JWT replaced the stored one; the refresh token is untouched.
        XCTAssertEqual(try store.load()?.token, "jwt_rotated")
        XCTAssertEqual(try store.load()?.refreshToken, "rt")
    }

    func testSetActiveOrganizationNullClearsIt() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"session","id":"sess_1","jwt":"jwt_x","expires_in":60,"last_active_organization_id":null}"#)
        let (client, _) = signedInClient()
        let active = try await client.setActiveOrganization(nil)
        XCTAssertNil(active)
        XCTAssertTrue(try body(0)["active_organization_id"] is NSNull)
    }

    // MARK: sessions / devices

    func testSessionsDecodeDeviceList() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"""
        {"object":"list","data":[
          {"object":"session","id":"sess_1","status":"active","current":true,"last_active_at":1700000000000,"expire_at":1700001000000,"created_at":1699999000000,"ip_address":"1.2.3.4","device_label":"Chrome on macOS","browser":"Chrome","os":"macOS","device_type":"desktop","location":"Berlin, DE"}
        ]}
        """#)
        let (client, _) = signedInClient()
        let devices = try await client.sessions()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.current, true)
        XCTAssertEqual(devices.first?.deviceLabel, "Chrome on macOS")
        XCTAssertEqual(devices.first?.location, "Berlin, DE")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sessions")
    }

    func testRevokeSessionForCurrentClearsStore() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"session","id":"sess_1","status":"revoked"}"#)
        let (client, store) = signedInClient()
        try await client.revokeSession(id: "sess_1")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sessions/sess_1/revoke")
        // Revoking the current session signs this device out locally too.
        XCTAssertNil(try store.load())
    }

    func testRevokeSessionForOtherDeviceKeepsStore() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"session","id":"sess_other","status":"revoked"}"#)
        let (client, store) = signedInClient()
        try await client.revokeSession(id: "sess_other")
        XCTAssertNotNil(try store.load())
    }

    func testRevokeOtherSessionsReturnsCount() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"client","sessions_revoked":3}"#)
        let (client, _) = signedInClient()
        let count = try await client.revokeOtherSessions()
        XCTAssertEqual(count, 3)
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sessions/revoke_all")
    }

    // MARK: /me emails

    func testAddEmailAddress() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"email_address","id":"email_2","email_address":"new@b.com","verified":false,"primary":false}"#)
        let (client, _) = signedInClient()
        let result = try await client.addEmailAddress("new@b.com")
        XCTAssertEqual(result.id, "email_2")
        XCTAssertEqual(result.emailAddress, "new@b.com")
        XCTAssertEqual(result.verified, false)
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/email_addresses")
        XCTAssertEqual(try body(0)["email_address"] as? String, "new@b.com")
    }

    func testVerifyEmailAddress() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"email_address","id":"email_2","email_address":"new@b.com","verified":true}"#)
        let (client, _) = signedInClient()
        let result = try await client.verifyEmailAddress(id: "email_2", code: "123456")
        XCTAssertEqual(result.verified, true)
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/email_addresses/email_2/attempt_verification")
        XCTAssertEqual(try body(0)["code"] as? String, "123456")
    }

    func testRemoveEmailAddressUsesDelete() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"email_address","id":"email_2","deleted":true}"#)
        let (client, _) = signedInClient()
        try await client.removeEmailAddress(id: "email_2")
        XCTAssertEqual(MockURLProtocol.recorded[0].httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/email_addresses/email_2")
    }

    // MARK: /me external accounts

    func testConnectExternalAccountBody() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"object":"external_account_connection","provider":"github","attempt_id":"att_1","authorization_url":"https://github.com/login/oauth/authorize?x=1","scopes":["read:user","repo"]}"#)
        let (client, _) = signedInClient()
        let connection = try await client.connectExternalAccount(
            provider: "github", redirectURL: "myapp://cb", additionalScopes: ["repo"]
        )
        XCTAssertEqual(connection.provider, "github")
        XCTAssertEqual(connection.attemptId, "att_1")
        XCTAssertEqual(connection.scopes, ["read:user", "repo"])
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/external_accounts/connect")
        XCTAssertEqual(try body(0)["provider"] as? String, "github")
        XCTAssertEqual(try body(0)["redirect_url"] as? String, "myapp://cb")
        XCTAssertEqual(try body(0)["additional_scopes"] as? [String], ["repo"])
    }

    // MARK: /me password + profile

    func testChangePasswordBody() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"user","id":"user_1","sessions_revoked":2}"#)
        let (client, _) = signedInClient()
        try await client.changePassword(current: "old", new: "new")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/change_password")
        XCTAssertEqual(try body(0)["current_password"] as? String, "old")
        XCTAssertEqual(try body(0)["new_password"] as? String, "new")
    }

    func testUpdateProfileSendsUnsafeMetadataAsJSONObject() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"user","id":"user_1","first_name":"Ada","email_addresses":[],"external_accounts":[],"passkeys":[]}"#)
        let (client, _) = signedInClient()
        let user = try await client.updateProfile(
            firstName: "Ada",
            unsafeMetadata: ["theme": .string("dark"), "count": .number(3), "flags": .object(["beta": .bool(true)])]
        )
        XCTAssertEqual(user.firstName, "Ada")
        XCTAssertEqual(MockURLProtocol.recorded[0].httpMethod, "PATCH")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me")
        let sent = try body(0)
        XCTAssertEqual(sent["first_name"] as? String, "Ada")
        // public_metadata is never sent from the client.
        XCTAssertNil(sent["public_metadata"])
        let meta = try XCTUnwrap(sent["unsafe_metadata"] as? [String: Any])
        XCTAssertEqual(meta["theme"] as? String, "dark")
        XCTAssertEqual(meta["count"] as? Double, 3)
        XCTAssertEqual((meta["flags"] as? [String: Any])?["beta"] as? Bool, true)
    }

    // MARK: not-signed-in guard

    func testAuthenticatedCallWithoutSessionThrowsNotSignedIn() async {
        let client = AtlasClient(
            publishableKey: pk, frontendApi: "clerk.example.com",
            tokenStore: InMemoryTokenStore(), urlSession: MockURLProtocol.makeSession()
        )
        do {
            _ = try await client.organizations()
            XCTFail("expected notSignedIn")
        } catch let error as AtlasError {
            guard case .notSignedIn = error else { return XCTFail("expected .notSignedIn, got \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
