import XCTest
@testable import Atlas

/// Policy acceptance: the wire types, the acceptance state a UI drives, the HTML
/// reader, and the flows that hold a sign-in or sign-up for a policy. Everything
/// runs against the mocked transport, so it needs no device and no UI.
final class PolicyTests: XCTestCase {
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

    private func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.recordedBodies[index]) as? [String: Any])
    }

    private func tos(
        display: AtlasPolicyDisplay = .checkbox, required: Bool = true, version: String = "polv_tos1"
    ) -> AtlasPolicy {
        AtlasPolicy(
            key: "tos", title: "Terms of Service", display: display, required: required,
            versionId: version, version: "2026-10-24", contentHTML: "<p>Terms.</p>", contentSHA256: "aa11"
        )
    }

    private func privacy(display: AtlasPolicyDisplay = .checkbox) -> AtlasPolicy {
        AtlasPolicy(
            key: "privacy", title: "Privacy Policy", display: display, required: true,
            versionId: "polv_pr1", version: "1", contentHTML: "<p>Privacy.</p>", contentSHA256: "bb22"
        )
    }

    // MARK: decoding

    func testPoliciesListDecodesAndSortsByPosition() throws {
        let json = #"""
        {"object":"list","data":[
          {"object":"policy","key":"privacy","title":"Privacy Policy","display":"link","required":true,
           "applies_to":"sign_in_and_sign_up","position":2,"version_id":"polv_2","version":"3",
           "content_markdown":null,"content_html":"<p>P</p>","content_sha256":"h2","content_url":null,
           "summary_of_changes":"New section","locale":"en","published_at":1760000000000,"effective_at":1760000001000},
          {"object":"policy","key":"tos","title":"Terms","display":"scroll","required":true,
           "applies_to":"sign_up","position":1,"version_id":"polv_1","version":"2026-10-24",
           "content_html":"<p>T</p>","content_sha256":"h1","published_at":null,"effective_at":"2026-10-24T00:00:00Z"}
        ],"legacy_consent":{"required":true,"terms_url":"https://x.test/t","privacy_url":null}}
        """#
        let list = try JSONDecoder().decode(AtlasPolicies.self, from: Data(json.utf8))
        XCTAssertEqual(list.policies.map(\.key), ["tos", "privacy"])
        XCTAssertEqual(list.policies[0].display, .scroll)
        XCTAssertEqual(list.policies[1].display, .link)
        XCTAssertEqual(list.policies[1].publishedAt, 1_760_000_000_000)
        XCTAssertEqual(list.policies[0].effectiveAt, 1_792_800_000_000)
        XCTAssertEqual(list.policies[1].summaryOfChanges, "New section")
        XCTAssertEqual(list.legacyConsent, AtlasPolicies.LegacyConsent(required: true, termsURL: "https://x.test/t"))
        XCTAssertEqual(list.policies[0].id, "tos@polv_1")
    }

    func testUnknownDisplayFallsBackToCheckbox() throws {
        let json = #"{"policy":"x","title":"X","display":"hologram","version_id":"v","content_sha256":"h"}"#
        let pending = try JSONDecoder().decode(PendingPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(pending.display, .checkbox)
        XCTAssertEqual(pending.policy, "x")
    }

    func testAttemptDecodesPendingPoliciesAndToken() throws {
        let json = #"""
        {"id":"sia_9","status":"needs_policy_acceptance","policy_acceptance_token":"pat_1",
         "pending_policies":[{"policy":"tos","policy_id":"pol_1","title":"Terms","display":"scroll",
           "version_id":"polv_1","version":"2","content_sha256":"h1","reaccept":"next_sign_in",
           "summary_of_changes":"Changed"}]}
        """#
        let attempt = try JSONDecoder().decode(SignInAttempt.self, from: Data(json.utf8))
        XCTAssertEqual(attempt.policyAcceptanceToken, "pat_1")
        XCTAssertEqual(attempt.pendingPolicies?.first?.policy, "tos")
        XCTAssertEqual(attempt.pendingPolicies?.first?.summaryOfChanges, "Changed")
        guard case let .acceptPolicies(pending) = signInStep(attempt) else { return XCTFail("expected acceptPolicies") }
        XCTAssertEqual(pending.count, 1)
    }

    func testStandingsDecode() throws {
        let json = #"""
        {"object":"list","needs_acceptance":true,"blocking":false,"data":[
          {"policy":"tos","policy_id":"pol_1","title":"Terms","display":"checkbox","required":true,
           "applies_to":"sign_in_and_sign_up","reaccept":"grace","current_version_id":"polv_2",
           "current_version":"2","content_sha256":"h","summary_of_changes":null,"accepted_version_id":"polv_1",
           "accepted_version":"1","accepted_at":1760000000000,"needs_reaccept":true,"blocking":false,
           "grace_ends_at":1761000000000}]}
        """#
        let mine = try JSONDecoder().decode(MyPolicies.self, from: Data(json.utf8))
        XCTAssertTrue(mine.needsAcceptance)
        XCTAssertEqual(mine.pending.map(\.policy), ["tos"])
        XCTAssertEqual(mine.standings[0].graceEndsAt, 1_761_000_000_000)
    }

    // MARK: acceptance state

    func testCheckboxMustBeTickedAndBuildsEvidence() {
        var state = PolicyAcceptanceState(policies: [tos(), privacy()])
        XCTAssertFalse(state.canSubmit)
        XCTAssertFalse(state.allCheckboxesTicked)
        state.setAllCheckboxes(true)
        XCTAssertTrue(state.canSubmit)
        XCTAssertTrue(state.allCheckboxesTicked)

        let start = Date(timeIntervalSince1970: 1000)
        state.beginReading(state.policies[0], at: start)
        state.endReading(state.policies[0], at: start.addingTimeInterval(2.5))
        state.markScrolledToEnd(state.policies[0])

        let built = state.build(locale: "fr")
        XCTAssertEqual(built.count, 2)
        XCTAssertEqual(built[0].policy, "tos")
        XCTAssertEqual(built[0].versionId, "polv_tos1")
        XCTAssertEqual(built[0].contentSHA256, "aa11")
        XCTAssertEqual(built[0].viewMs, 2500)
        XCTAssertEqual(built[0].scrolledToEnd, true)
        XCTAssertNil(built[1].viewMs)
        XCTAssertNil(built[1].scrolledToEnd)
        XCTAssertEqual(built[0].locale, "fr")
        let json = built[0].json
        XCTAssertEqual(json["version_id"] as? String, "polv_tos1")
        XCTAssertEqual(json["display"] as? String, "checkbox")
        XCTAssertEqual(json["view_ms"] as? Int, 2500)
        XCTAssertEqual(json["scrolled_to_end"] as? Bool, true)
    }

    func testUntickedOptionalCheckboxIsNotSent() {
        var state = PolicyAcceptanceState(policies: [tos(), privacy()])
        state.setTicked(state.policies[0], true)
        XCTAssertFalse(state.canSubmit) // privacy is required
        let optional = AtlasPolicy(
            key: "news", title: "Newsletter", required: false, versionId: "n1", contentSHA256: "cc"
        )
        var withOptional = PolicyAcceptanceState(policies: [optional])
        XCTAssertTrue(withOptional.canSubmit)
        XCTAssertTrue(withOptional.build().isEmpty)
        withOptional.setTicked(optional, true)
        XCTAssertEqual(withOptional.build().map(\.policy), ["news"])
    }

    func testScrollPolicyNeedsItsSheetAndSendsScrolledToEnd() {
        var state = PolicyAcceptanceState(policies: [tos(display: .scroll)])
        XCTAssertTrue(state.canSubmit) // shown on submit, not a precondition
        XCTAssertEqual(state.pendingScroll.map(\.key), ["tos"])
        XCTAssertFalse(state.isComplete)
        XCTAssertTrue(state.build().isEmpty)

        state.acceptScroll(state.policies[0])
        XCTAssertTrue(state.pendingScroll.isEmpty)
        XCTAssertTrue(state.isComplete)
        let built = state.build()
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].display, .scroll)
        XCTAssertEqual(built[0].scrolledToEnd, true)
    }

    func testClickwrapIsAcceptedBySubmitting() {
        let state = PolicyAcceptanceState(policies: [privacy(display: .link)])
        XCTAssertTrue(state.canSubmit)
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.build().map(\.policy), ["privacy"])
        XCTAssertEqual(state.build().first?.display, .link)
    }

    func testReloadKeepsTicksForUnchangedVersionsOnly() {
        var state = PolicyAcceptanceState(policies: [tos(), privacy()])
        state.setAllCheckboxes(true)
        state.setPolicies([tos(), privacy().with(versionId: "polv_pr2")])
        XCTAssertTrue(state.isTicked(state.policies[0]))
        XCTAssertFalse(state.isTicked(state.policies[1])) // a new version needs a new tick
        XCTAssertFalse(state.canSubmit)
    }

    func testViewTimeAccumulatesAcrossOpens() {
        var state = PolicyAcceptanceState(policies: [tos()])
        let p = state.policies[0]
        let t0 = Date(timeIntervalSince1970: 0)
        state.beginReading(p, at: t0)
        state.endReading(p, at: t0.addingTimeInterval(1))
        state.beginReading(p, at: t0.addingTimeInterval(10))
        state.endReading(p, at: t0.addingTimeInterval(11.5))
        state.endReading(p, at: t0.addingTimeInterval(20)) // not open: ignored
        XCTAssertEqual(state.viewDuration(p), 2500)
    }

    func testScrollEndDecision() {
        XCTAssertTrue(PolicyScroll.reachedEnd(endMaxY: 300, viewportHeight: 500)) // fits
        XCTAssertTrue(PolicyScroll.reachedEnd(endMaxY: 501, viewportHeight: 500)) // within tolerance
        XCTAssertFalse(PolicyScroll.reachedEnd(endMaxY: 900, viewportHeight: 500))
        XCTAssertFalse(PolicyScroll.reachedEnd(endMaxY: .infinity, viewportHeight: 500))
        XCTAssertFalse(PolicyScroll.reachedEnd(endMaxY: 10, viewportHeight: 0)) // not laid out yet
    }

    func testJoinedTitles() {
        XCTAssertEqual(PolicyText.join([]), "")
        XCTAssertEqual(PolicyText.join(["A"]), "A")
        XCTAssertEqual(PolicyText.join(["A", "B"]), "A and B")
        XCTAssertEqual(PolicyText.join(["A", "B", "C"]), "A, B and C")
        XCTAssertEqual(PolicyText.agree(["Terms", "Privacy"]), "I agree to the Terms and Privacy")
    }

    // MARK: HTML reader

    func testReaderBlocksAndInlineStyles() {
        let html = #"""
        <h2>Terms &amp; Conditions</h2>
        <p>Read <strong>this</strong> and <em>that</em>, see <a href="https://x.test/a?b=1&amp;c=2">the site</a>.</p>
        <ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>
        <ol><li>First</li><li>Second</li></ol>
        <blockquote><p>Quoted</p></blockquote>
        <pre>a  b
        c</pre><hr><p>End&nbsp;&#169;&#x2122;</p>
        """#
        let blocks = PolicyHTML.parse(html)
        XCTAssertEqual(blocks[0].kind, .heading(2))
        XCTAssertEqual(blocks[0].plainText, "Terms & Conditions")

        XCTAssertEqual(blocks[1].kind, .paragraph)
        XCTAssertEqual(blocks[1].plainText, "Read this and that, see the site.")
        XCTAssertTrue(blocks[1].runs.contains { $0.text == "this" && $0.bold })
        XCTAssertTrue(blocks[1].runs.contains { $0.text == "that" && $0.italic })
        XCTAssertTrue(blocks[1].runs.contains { $0.link == "https://x.test/a?b=1&c=2" && $0.text == "the site" })

        XCTAssertEqual(blocks[2].kind, .listItem(marker: "\u{2022}"))
        XCTAssertEqual(blocks[2].plainText, "One")
        XCTAssertEqual(blocks[3].plainText, "Two")
        XCTAssertEqual(blocks[4].plainText, "Nested")
        XCTAssertEqual(blocks[4].indent, 1)
        XCTAssertEqual(blocks[5].kind, .listItem(marker: "1."))
        XCTAssertEqual(blocks[6].kind, .listItem(marker: "2."))
        XCTAssertEqual(blocks[7].kind, .quote)
        XCTAssertEqual(blocks[7].plainText, "Quoted")
        XCTAssertEqual(blocks[8].kind, .preformatted)
        XCTAssertTrue(blocks[8].plainText.hasPrefix("a  b\n"))
        XCTAssertEqual(blocks[9].kind, .rule)
        XCTAssertEqual(blocks[10].plainText, "End \u{00A9}\u{2122}")
    }

    func testReaderDropsScriptsAndUnsafeLinks() {
        let html = #"<p>Hi<script>alert(1)</script> <a href="javascript:alert(1)">x</a> <a href="mailto:a@b.test">mail</a><style>p{}</style></p>"#
        let blocks = PolicyHTML.parse(html)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].plainText, "Hi x mail")
        XCTAssertFalse(blocks[0].plainText.contains("alert"))
        XCTAssertNil(blocks[0].runs.first { $0.text == "x" }?.link)
        XCTAssertEqual(blocks[0].runs.first { $0.text == "mail" }?.link, "mailto:a@b.test")
    }

    func testReaderToleratesStrayAngleBracketsAndEmptyInput() {
        XCTAssertTrue(PolicyHTML.parse("").isEmpty)
        XCTAssertTrue(PolicyHTML.parse("   \n ").isEmpty)
        let blocks = PolicyHTML.parse("<p>1 < 2 and 3 > 2</p>")
        XCTAssertEqual(blocks.first?.plainText, "1 < 2 and 3 > 2")
        let fromMarkdown = PolicyHTML.blocks(html: "", markdown: "One\n\nTwo")
        XCTAssertEqual(fromMarkdown.map(\.plainText), ["One", "Two"])
    }

    // MARK: client calls

    func testLoadPoliciesSendsLocaleAndKey() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"""
        {"object":"list","data":[{"key":"tos","title":"Terms","display":"checkbox","required":true,
          "version_id":"polv_1","version":"1","content_html":"<p>T</p>","content_sha256":"h"}],"legacy_consent":null}
        """#)
        let list = try await makeClient().policies(locale: "pt-BR")
        XCTAssertEqual(list.policies.count, 1)
        let req = MockURLProtocol.recorded[0]
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/v1/client/policies")
        XCTAssertEqual(req.url?.query, "locale=pt-BR")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-publishable-key"), "pk_test_123")
        XCTAssertNil(list.legacyConsent)
    }

    func testResolvingPendingFillsContentByKey() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"""
        {"object":"list","data":[
          {"key":"tos","title":"Terms","display":"checkbox","required":false,"version_id":"polv_2","version":"2",
           "content_html":"<p>Full text</p>","content_sha256":"h2"},
          {"key":"other","title":"Other","display":"checkbox","required":true,"version_id":"o1","version":"1",
           "content_html":"<p>O</p>","content_sha256":"ho"}]}
        """#)
        let pending = [
            PendingPolicy(policy: "tos", title: "Terms", display: .scroll, versionId: "polv_2", version: "2", contentSHA256: "h2"),
            PendingPolicy(policy: "gone", title: "Gone", versionId: "g1", contentSHA256: "hg"),
        ]
        let policies = try await makeClient().policies(resolving: pending)
        XCTAssertEqual(policies.map(\.key), ["tos", "gone"])
        XCTAssertEqual(policies[0].display, .scroll) // the attempt's display wins
        XCTAssertTrue(policies[0].required) // always required of a held sign-in
        XCTAssertEqual(policies[0].contentHTML, "<p>Full text</p>")
        XCTAssertFalse(policies[1].hasContent)
    }

    func testResolvingEmptyPendingReturnsRequiredPolicies() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"""
        {"object":"list","data":[
          {"key":"tos","title":"Terms","required":true,"version_id":"v1","content_sha256":"h"},
          {"key":"news","title":"News","required":false,"version_id":"v2","content_sha256":"h"}]}
        """#)
        let policies = try await makeClient().policies(resolving: [])
        XCTAssertEqual(policies.map(\.key), ["tos"])
    }

    func testMyPoliciesAndInAppAccept() async throws {
        let store = InMemoryTokenStore(AtlasSession(sessionId: "sess_1", token: "jwt", refreshToken: "rt"))
        let client = makeClient(store: store)
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"list","needs_acceptance":true,"blocking":false,"data":[{"policy":"tos","title":"T","needs_reaccept":true}]}"#)
        let mine = try await client.myPolicies()
        XCTAssertEqual(mine.pending.map(\.policy), ["tos"])
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/me/policies")
        XCTAssertEqual(MockURLProtocol.recorded[0].httpMethod, "GET")
        XCTAssertTrue(MockURLProtocol.recorded[0].value(forHTTPHeaderField: "Cookie")?.contains("__session=jwt") == true)

        MockURLProtocol.enqueue(status: 201, json: #"{"object":"list","data":[],"standings":[{"policy":"tos","title":"T","needs_reaccept":false}]}"#)
        let accepted = try await client.acceptMyPolicies(buildPolicyAcceptances([tos()], evidence: ["tos": PolicyEvidence(scrolledToEnd: true, viewMs: 900)]))
        XCTAssertEqual(accepted.standings.first?.needsReaccept, false)
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/me/policies/accept")
        XCTAssertEqual(MockURLProtocol.recorded[1].httpMethod, "POST")
        let sent = try XCTUnwrap(try body(1)["policy_acceptances"] as? [[String: Any]])
        XCTAssertEqual(sent.first?["policy"] as? String, "tos")
        XCTAssertEqual(sent.first?["content_sha256"] as? String, "aa11")
        XCTAssertEqual(sent.first?["view_ms"] as? Int, 900)
    }

    func testMyPoliciesNeedsASession() async {
        do {
            _ = try await makeClient().myPolicies()
            XCTFail("expected notSignedIn")
        } catch let error as AtlasError {
            XCTAssertEqual(error.message, AtlasError.notSignedIn.message)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    // MARK: sign-up

    func testSignUpSendsPolicyAcceptances() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sua_1","status":"needs_email_verification"}"#)
        let flow = makeClient().signUpFlow()
        let step = try await flow.start(
            email: "a@b.com", password: "pw-pw-pw-1",
            policyAcceptances: buildPolicyAcceptances([tos(), privacy()], evidence: ["tos": PolicyEvidence(scrolledToEnd: true, viewMs: 1200)])
        )
        XCTAssertEqual(step, .collectEmailCode)
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ups")
        let sent = try XCTUnwrap(try body(0)["policy_acceptances"] as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["policy"] as? String }, ["tos", "privacy"])
        XCTAssertEqual(sent[0]["version_id"] as? String, "polv_tos1")
        XCTAssertEqual(sent[0]["scrolled_to_end"] as? Bool, true)
        XCTAssertEqual(sent[0]["view_ms"] as? Int, 1200)
        XCTAssertNil(sent[1]["view_ms"])
    }

    func testSignUpWithoutAcceptancesOmitsTheField() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sua_1","status":"needs_email_verification"}"#)
        _ = try await makeClient().signUpFlow().start(email: "a@b.com", password: "pw", consent: true)
        let sent = try body(0)
        XCTAssertNil(sent["policy_acceptances"])
        XCTAssertEqual(sent["consent"] as? Bool, true)
    }

    func testPolicyRequiredRefusalNamesTheProblems() async throws {
        MockURLProtocol.enqueue(status: 422, json: #"""
        {"errors":[{"code":"POLICY_ACCEPTANCE_REQUIRED","message":"Accept the current version of \"tos\" to continue.",
          "param":"policy_acceptances","meta":{"policies":[
            {"policy":"tos","title":"Terms","display":"scroll","version_id":"polv_9","version":"9",
             "content_sha256":"h9","summary_of_changes":"New","problem":"scroll_required"},
            {"policy":"privacy","title":"Privacy","display":"checkbox","version_id":"polv_3","problem":"stale_version"},
            {"policy":"x","title":"X","problem":"something_new"}]}}]}
        """#)
        do {
            _ = try await makeClient().signUpFlow().start(email: "a@b.com", password: "pw")
            XCTFail("expected AtlasError")
        } catch let error as AtlasError {
            XCTAssertTrue(error.isPolicyAcceptanceRequired)
            XCTAssertEqual(error.knownCode, .policyAcceptanceRequired)
            let problems = error.policyProblems
            XCTAssertEqual(problems.map(\.policy), ["tos", "privacy", "x"])
            XCTAssertEqual(problems.map(\.problem), [.scrollRequired, .staleVersion, .other])
            XCTAssertEqual(problems[0].display, .scroll)
            XCTAssertEqual(problems[0].versionId, "polv_9")
            XCTAssertEqual(problems[0].summaryOfChanges, "New")
        }
    }

    func testOtherErrorsHaveNoPolicyProblems() {
        let error = AtlasError.api(status: 422, errors: [AtlasErrorItem(code: "VALIDATION_FAILED", message: "no")])
        XCTAssertFalse(error.isPolicyAcceptanceRequired)
        XCTAssertTrue(error.policyProblems.isEmpty)
    }

    func testPasskeySignUpSendsPolicyAcceptances() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sua_p","status":"needs_first_factor","supported_first_factors":["passkey"],"poll_secret":"ps"}"#)
        let flow = makeClient().passkeySignUpFlow()
        _ = try await flow.start(email: "a@b.com", policyAcceptances: buildPolicyAcceptances([tos()]))
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ups/passkey")
        let sent = try XCTUnwrap(try body(0)["policy_acceptances"] as? [[String: Any]])
        XCTAssertEqual(sent.first?["policy"] as? String, "tos")
    }

    // MARK: held sign-in

    private let heldJSON = #"""
    {"id":"sia_h","status":"needs_policy_acceptance","policy_acceptance_token":"pat_one",
     "pending_policies":[{"policy":"tos","title":"Terms","display":"checkbox","version_id":"polv_tos1",
       "version":"2026-10-24","content_sha256":"aa11"}]}
    """#

    func testHeldSignInAcceptsWithTheToken() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_h","status":"needs_first_factor","supported_first_factors":["password"]}"#)
        MockURLProtocol.enqueue(status: 200, json: heldJSON)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_h","status":"complete","created_session_id":"sess_h","ticket":"tk_h"}"#)
        MockURLProtocol.enqueue(
            status: 200, json: #"{"id":"sess_h","jwt":"jwt_h","expires_in":60}"#,
            headers: ["Set-Cookie": "__atlas_rt=rt_h; Path=/; HttpOnly"]
        )
        let store = InMemoryTokenStore()
        let flow = makeClient(store: store).signInFlow()
        _ = try await flow.start(identifier: "a@b.com")
        let held = try await flow.attemptPassword("pw")
        guard case let .acceptPolicies(pending) = held else { return XCTFail("expected acceptPolicies, got \(held)") }
        XCTAssertEqual(pending.map(\.policy), ["tos"])
        let listed = await flow.pendingPolicies
        XCTAssertEqual(listed.count, 1)

        let done = try await flow.acceptPolicies(buildPolicyAcceptances([tos()]))
        XCTAssertEqual(done, .done(sessionId: "sess_h"))
        XCTAssertEqual(MockURLProtocol.recorded[2].url?.path, "/v1/client/sign_ins/sia_h/accept_policies")
        XCTAssertEqual(MockURLProtocol.recorded[2].httpMethod, "POST")
        let sent = try body(2)
        XCTAssertEqual(sent["policy_acceptance_token"] as? String, "pat_one")
        XCTAssertNil(sent["poll_secret"])
        XCTAssertEqual((sent["policy_acceptances"] as? [[String: Any]])?.first?["policy"] as? String, "tos")
        XCTAssertEqual(MockURLProtocol.recorded[3].url?.path, "/v1/client/tickets/exchange")
        XCTAssertEqual(try store.load()?.token, "jwt_h")
    }

    func testAcceptRefusalKeepsTheAttemptAndTokenForARetry() async throws {
        let flow = makeClient().signInFlow(attempt: try JSONDecoder().decode(SignInAttempt.self, from: Data(heldJSON.utf8)))
        MockURLProtocol.enqueue(status: 422, json: #"{"errors":[{"code":"POLICY_ACCEPTANCE_REQUIRED","message":"stale","meta":{"policies":[{"policy":"tos","title":"Terms","problem":"stale_version"}]}}]}"#)
        do {
            _ = try await flow.acceptPolicies([])
            XCTFail("expected AtlasError")
        } catch let error as AtlasError {
            XCTAssertTrue(error.isPolicyAcceptanceRequired)
        }
        let stillHeld = await flow.step
        guard case .acceptPolicies = stillHeld else { return XCTFail("attempt lost: \(stillHeld)") }

        // A newer version was published: the server holds it again with a fresh token.
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_h","status":"needs_policy_acceptance","policy_acceptance_token":"pat_two","pending_policies":[{"policy":"tos","title":"Terms","version_id":"polv_tos2","content_sha256":"zz"}]}"#)
        let again = try await flow.acceptPolicies(buildPolicyAcceptances([tos()]))
        guard case let .acceptPolicies(pending) = again else { return XCTFail("expected acceptPolicies") }
        XCTAssertEqual(pending.first?.versionId, "polv_tos2")

        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_h","status":"needs_second_factor"}"#)
        _ = try await flow.acceptPolicies(buildPolicyAcceptances([tos(version: "polv_tos2")]))
        // The second call used the first call's (spent) token for request 2, the fresh one for request 3.
        XCTAssertEqual(try body(0)["policy_acceptance_token"] as? String, "pat_one")
        XCTAssertEqual(try body(1)["policy_acceptance_token"] as? String, "pat_one")
        XCTAssertEqual(try body(2)["policy_acceptance_token"] as? String, "pat_two")
    }

    func testPollSecretIsTheFallbackProof() async throws {
        let attempt = SignInAttempt(id: "sia_q", status: "needs_policy_acceptance")
        let flow = SignInFlow(client: makeClient(), attempt: attempt)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_q","status":"needs_second_factor"}"#)
        let step = try await flow.acceptPolicies(buildPolicyAcceptances([tos()]), pollSecret: "ps_1")
        XCTAssertEqual(step, .collectSecondFactor)
        let sent = try body(0)
        XCTAssertEqual(sent["poll_secret"] as? String, "ps_1")
        XCTAssertNil(sent["policy_acceptance_token"])
    }

    func testAcceptWithoutAnAttemptThrows() async {
        let flow = makeClient().signInFlow()
        do {
            _ = try await flow.acceptPolicies([])
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
        }
    }

    func testHeldSignUpAcceptsThroughTheSameRoute() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sua_h","status":"needs_policy_acceptance","policy_acceptance_token":"pat_su","pending_policies":[{"policy":"tos","title":"T","version_id":"v","content_sha256":"h"}]}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sua_h","status":"needs_email_verification"}"#)
        let flow = makeClient().signUpFlow()
        let held = try await flow.start(email: "a@b.com", password: "pw")
        guard case .acceptPolicies = held else { return XCTFail("expected acceptPolicies") }
        let next = try await flow.acceptPolicies(buildPolicyAcceptances([tos()]))
        XCTAssertEqual(next, .collectEmailCode)
        XCTAssertEqual(MockURLProtocol.recorded[1].url?.path, "/v1/client/sign_ins/sua_h/accept_policies")
        XCTAssertEqual(try body(1)["policy_acceptance_token"] as? String, "pat_su")
    }

    func testPasswordResetHeldForPolicies() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"pr_1","status":"needs_policy_acceptance","policy_acceptance_token":"pat_pr"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"pr_1","status":"needs_new_password"}"#)
        let flow = makeClient().passwordResetFlow()
        let held = try await flow.start(email: "a@b.com")
        XCTAssertEqual(held, .acceptPolicies(pending: []))
        let next = try await flow.acceptPolicies(buildPolicyAcceptances([tos()]))
        XCTAssertEqual(next, .collectNewPassword)
        XCTAssertEqual(try body(1)["policy_acceptance_token"] as? String, "pat_pr")
    }

    func testIdTokenSignInHeldForPoliciesHandsBackAFlowWithTheToken() async throws {
        MockURLProtocol.enqueue(status: 200, json: heldJSON)
        let outcome = try await makeClient().signInWithIdToken(provider: "apple", idToken: "x.y.z")
        guard case let .needsNextStep(flow) = outcome else { return XCTFail("expected needsNextStep") }
        let step = await flow.step
        guard case let .acceptPolicies(pending) = step else { return XCTFail("expected acceptPolicies") }
        XCTAssertEqual(pending.first?.policy, "tos")

        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_h","status":"needs_second_factor"}"#)
        _ = try await flow.acceptPolicies(buildPolicyAcceptances([tos()]))
        XCTAssertEqual(try body(1)["policy_acceptance_token"] as? String, "pat_one")
    }

    // MARK: redirect callbacks

    func testRedirectKeepsThePolicyToken() async throws {
        let url = try XCTUnwrap(URL(string: "myapp://callback?__atlas_attempt=sia_r&__atlas_status=needs_policy_acceptance&__atlas_policy_token=pat_r&x=1"))
        let result = try XCTUnwrap(AtlasRedirectResult(url: url))
        XCTAssertEqual(result.attemptId, "sia_r")
        XCTAssertEqual(result.status, "needs_policy_acceptance")
        XCTAssertEqual(result.policyToken, "pat_r")
        XCTAssertNil(result.ticket)

        let client = makeClient()
        let outcome = try await client.completeRedirect(url)
        guard case let .needsNextStep(flow) = try XCTUnwrap(outcome) else { return XCTFail("expected needsNextStep") }
        let step = await flow.step
        XCTAssertEqual(step, .acceptPolicies(pending: []))
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty) // nothing sent just to read a URL

        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sia_r","status":"complete","created_session_id":"sess_r","ticket":"tk_r"}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_r","jwt":"jwt_r","expires_in":60}"#)
        let done = try await flow.acceptPolicies(buildPolicyAcceptances([tos()]))
        XCTAssertEqual(done, .done(sessionId: "sess_r"))
        XCTAssertEqual(MockURLProtocol.recorded[0].url?.path, "/v1/client/sign_ins/sia_r/accept_policies")
        XCTAssertEqual(try body(0)["policy_acceptance_token"] as? String, "pat_r")
    }

    func testRedirectTokenIgnoredForOtherStatusesAndStrayParams() throws {
        let other = try XCTUnwrap(URL(string: "myapp://cb?__atlas_attempt=a&__atlas_status=needs_second_factor&__atlas_policy_token=t"))
        XCTAssertNil(AtlasRedirectResult(url: other)?.policyToken)
        XCTAssertNil(AtlasRedirectResult(url: try XCTUnwrap(URL(string: "myapp://cb?__atlas_attempt=a"))))
        XCTAssertNil(AtlasRedirectResult(url: try XCTUnwrap(URL(string: "myapp://cb?other=1"))))
        let ticketed = try XCTUnwrap(AtlasRedirectResult(url: try XCTUnwrap(URL(string: "myapp://cb?__atlas_attempt=a&__atlas_ticket=tk"))))
        XCTAssertEqual(ticketed.ticket, "tk")
    }

    func testRedirectWithATicketSignsIn() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"sess_t","jwt":"jwt_t","expires_in":60}"#)
        MockURLProtocol.enqueue(status: 200, json: #"{"id":"user_1"}"#)
        let url = try XCTUnwrap(URL(string: "myapp://cb?__atlas_attempt=sia_t&__atlas_ticket=tk_t"))
        let outcome = try await makeClient().completeRedirect(url)
        guard case let .signedIn(user) = try XCTUnwrap(outcome) else { return XCTFail("expected signedIn") }
        XCTAssertEqual(user.id, "user_1")
        let notAtlas = try await makeClient().completeRedirect(try XCTUnwrap(URL(string: "myapp://cb?x=1")))
        XCTAssertNil(notAtlas)
    }
}

private extension AtlasPolicy {
    /// The same policy at another version (the hash changes with the content).
    func with(versionId: String) -> AtlasPolicy {
        AtlasPolicy(
            key: key, title: title, display: display, required: required, appliesTo: appliesTo,
            position: position, versionId: versionId, version: version, contentMarkdown: contentMarkdown,
            contentHTML: contentHTML, contentSHA256: contentSHA256 + "x", summaryOfChanges: summaryOfChanges
        )
    }
}

private extension AtlasClient {
    func signInFlow(attempt: SignInAttempt) -> SignInFlow { SignInFlow(client: self, attempt: attempt) }
    func passkeySignUpFlow() -> PasskeySignUpFlow { PasskeySignUpFlow(client: self) }
}
