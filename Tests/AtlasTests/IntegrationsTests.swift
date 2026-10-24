import XCTest
@testable import Atlas

/// Integration `getToken`, the OIDC org / SSO claims, and the 2026-10 error codes.
final class IntegrationsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeClient(signedIn: Bool = true) -> AtlasClient {
        let store = InMemoryTokenStore()
        if signedIn {
            try? store.save(AtlasSession(sessionId: "sess_1", token: "jwt_1", refreshToken: "rt_1"))
        }
        return AtlasClient(
            publishableKey: "atlas_test_pk_abc",
            frontendApi: "clerk.example.com",
            tokenStore: store,
            urlSession: MockURLProtocol.makeSession()
        )
    }

    func testGetTokenPostsToTheSessionIntegrationRoute() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"jwt":"t.t.t","expires_in":300,"integration":"chatly","audience":"chatly"}"#)
        let token = try await makeClient().getToken(for: "chatly")
        XCTAssertEqual(token?.jwt, "t.t.t")
        XCTAssertEqual(token?.expiresIn, 300)
        XCTAssertEqual(token?.audience, "chatly")
        let request = MockURLProtocol.recorded[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/client/sessions/sess_1/integration_tokens/chatly")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-publishable-key"), "atlas_test_pk_abc")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("__atlas_rt=rt_1") == true)
    }

    func testGetTokenCarriesTheForumulateSpace() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"jwt":"j","expires_in":60,"integration":"forumulate","audience":"a","org_id":"o1","space_id":"s1","redeem_url":"https://f.example/redeem"}"#)
        let token = try await makeClient().getToken(for: "forumulate", spaceId: "s 1")
        XCTAssertEqual(token?.orgId, "o1")
        XCTAssertEqual(token?.redeemUrl, "https://f.example/redeem")
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.query, "space_id=s%201")
    }

    func testGetTokenIsNilWhenTheIntegrationIsNotEnabled() async throws {
        MockURLProtocol.enqueue(status: 404, json: #"{"errors":[{"code":"NOT_FOUND","message":"nope"}]}"#)
        let token = try await makeClient().getToken(for: "chatly")
        XCTAssertNil(token)
    }

    func testGetTokenThrowsOnOtherRefusalsAndWithoutASession() async throws {
        MockURLProtocol.enqueue(status: 401, json: #"{"errors":[{"code":"UNAUTHENTICATED","message":"no"}]}"#)
        do {
            _ = try await makeClient().getToken(for: "chatly")
            XCTFail("expected a throw")
        } catch let error as AtlasError {
            XCTAssertEqual(error.status, 401)
        }
        do {
            _ = try await makeClient(signedIn: false).getToken(for: "chatly")
            XCTFail("expected a throw")
        } catch let error as AtlasError {
            guard case .notSignedIn = error else { return XCTFail("expected notSignedIn") }
        }
        XCTAssertEqual(MockURLProtocol.recorded.count, 1)
    }

    func testAtlasIdTokenSendsBearerOriginAndKeyInQueryWithoutCookies() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"jwt":"j","expires_in":300,"integration":"referalli","audience":"r","issuer":"https://atlasauth.net","jwks_uri":"https://atlasauth.net/jwks"}"#)
        let token = try await makeClient().getAtlasIdToken(for: "referalli", accessToken: "at_123", origin: "https://app.example")
        XCTAssertEqual(token?.issuer, "https://atlasauth.net")
        XCTAssertEqual(token?.jwksUri, "https://atlasauth.net/jwks")
        let request = MockURLProtocol.recorded[0]
        XCTAssertEqual(request.url?.path, "/v1/client/integrations/referalli/atlas_id_tokens")
        XCTAssertEqual(request.url?.query, "publishable_key=atlas_test_pk_abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at_123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://app.example")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testAtlasIdTokenUsesDpopWhenAProofIsGiven() async throws {
        MockURLProtocol.enqueue(status: 403, json: #"{"errors":[{"code":"ORIGIN_NOT_ALLOWED","message":"origin"}]}"#)
        do {
            _ = try await makeClient().getAtlasIdToken(for: "referalli", accessToken: "at_1", dpopProof: "proof")
            XCTFail("expected a throw")
        } catch let error as AtlasError {
            XCTAssertTrue(error.isOriginNotAllowed)
        }
        let request = MockURLProtocol.recorded[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "DPoP at_1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "DPoP"), "proof")
    }

    func testAtlasIdTokenIsNilOn404() async throws {
        MockURLProtocol.enqueue(status: 404, json: #"{"errors":[{"code":"NOT_FOUND","message":"n"}]}"#)
        let token = try await makeClient().getAtlasIdToken(for: "x", accessToken: "t")
        XCTAssertNil(token)
    }

    func testInsufficientScopeReadsTheRequiredScope() {
        let body = #"{"errors":[{"code":"INSUFFICIENT_SCOPE","message":"m","meta":{"required_scope":"webhooks:write"},"docs_url":"https://atlasauth.net/errors/INSUFFICIENT_SCOPE"}]}"#
        let error = parseErrorEnvelope(status: 403, data: Data(body.utf8))
        XCTAssertTrue(error.isInsufficientScope)
        XCTAssertEqual(error.requiredScope, "webhooks:write")
        if case let .api(_, items) = error {
            XCTAssertEqual(items[0].docsUrl, "https://atlasauth.net/errors/INSUFFICIENT_SCOPE")
        }
        // The old spelling is still tolerated.
        let legacy = AtlasError.api(status: 403, errors: [AtlasErrorItem(code: "SCOPE_MISSING", message: "m")])
        XCTAssertTrue(legacy.isInsufficientScope)
        XCTAssertNil(legacy.requiredScope)
    }

    func testStepUpAndOriginNotAllowedAreTyped() {
        let step = AtlasError.api(status: 403, errors: [AtlasErrorItem(code: "STEP_UP_REQUIRED", message: "m")])
        XCTAssertTrue(step.isStepUpRequired)
        XCTAssertFalse(step.isOriginNotAllowed)
        XCTAssertEqual(step.knownCode, .stepUpRequired)
        let origin = AtlasError.api(status: 403, errors: [AtlasErrorItem(code: "ORIGIN_NOT_ALLOWED", message: "m")])
        XCTAssertTrue(origin.isOriginNotAllowed)
    }

    func testRouteNotFoundCarriesSuggestions() {
        let body = #"{"errors":[{"code":"ROUTE_NOT_FOUND","message":"m","did_you_mean":["/v1/webhook_endpoints"],"allowed_methods":["GET","POST"]}]}"#
        let error = parseErrorEnvelope(status: 404, data: Data(body.utf8))
        XCTAssertTrue(error.isRouteNotFound)
        XCTAssertEqual(error.didYouMean, ["/v1/webhook_endpoints"])
        XCTAssertEqual(error.allowedMethods, ["GET", "POST"])
        let plain = AtlasError.api(status: 404, errors: [AtlasErrorItem(code: "NOT_FOUND", message: "m")])
        XCTAssertTrue(plain.didYouMean.isEmpty)
    }

    func testOidcClaimsReadOrgAndSsoClaims() throws {
        let json = #"{"org_id":"org_1","org_slug":"acme","org_role":"admin","org_permissions":["a:b","c:d"],"orgs":[{"id":"org_1","slug":"acme","role":"admin"},{"id":"org_2","slug":"b","role":"member"},{"slug":"skipped"}],"sso_connection_id":"sso_9","sso_tenant_id":"tid","sso_issuer":"https://login.example","sso_domain":"acme.com","sso_organization_id":"org_7","sso_connection_type":"saml"}"#
        let claims = OidcClaims(claims: try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8)))
        XCTAssertEqual(claims.orgId, "org_1")
        XCTAssertEqual(claims.orgRole, "admin")
        XCTAssertEqual(claims.orgPermissions, ["a:b", "c:d"])
        XCTAssertEqual(claims.orgs.count, 2)
        XCTAssertEqual(claims.orgs[1].role, "member")
        XCTAssertEqual(claims.sso?.connectionId, "sso_9")
        XCTAssertEqual(claims.sso?.domain, "acme.com")
        XCTAssertEqual(claims.ssoOrganizationId, "org_7")
        XCTAssertEqual(claims.ssoConnectionType, "saml")
        let none = OidcClaims(claims: ["sub": .string("u")])
        XCTAssertNil(none.orgId)
        XCTAssertNil(none.sso)
        XCTAssertNil(none.ssoOrganizationId)
        XCTAssertNil(none.ssoConnectionType)
        XCTAssertTrue(none.orgs.isEmpty)
    }

    func testOidcClaimsFromJwtAndScopes() {
        let payload = Data(#"{"org_id":"o","sso_connection_id":"s"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let claims = OidcClaims(jwt: "e30.\(payload).sig")
        XCTAssertEqual(claims?.orgId, "o")
        XCTAssertEqual(claims?.sso?.connectionId, "s")
        XCTAssertNil(OidcClaims(jwt: "not-a-jwt"))
        XCTAssertEqual(AtlasScopes.withOrganizations(["openid"]), ["openid", "organizations"])
        XCTAssertEqual(AtlasScopes.withOrganizations(["openid", "organizations"]), ["openid", "organizations"])
    }
}
