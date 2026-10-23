import Foundation

// Policy acceptance (terms of service, privacy policy, any policy the app
// defines) — the platform-independent half: wire types, the acceptance state a
// UI drives, the sanitized-HTML reader, and the Frontend API calls. The Swift peer
// of `@atlas/js`'s `policy-acceptance.ts` / `policies.ts`. The SwiftUI surfaces
// live in `PolicyUI.swift`.
//
// Nothing here is a security boundary: `scrolled_to_end` and `view_ms` are
// client-attested evidence the server records next to the acceptance.

// MARK: - wire types

/// How a policy asks for acceptance.
public enum AtlasPolicyDisplay: String, Sendable, Equatable {
    /// A checkbox ("I agree to the Terms"); the name opens the document.
    case checkbox
    /// An unskippable document: accepted only after the end was seen.
    case scroll
    /// Clickwrap text under the submit button; submitting accepts.
    case link

    /// An unknown display from a newer server is the safest explicit mode: a checkbox.
    init(wire: String?) { self = AtlasPolicyDisplay(rawValue: wire ?? "") ?? .checkbox }
}

/// A policy's current version, as `GET /v1/client/policies` serves it. Times are
/// epoch milliseconds. ``contentHTML`` is already sanitized by Atlas and is what
/// ``contentSHA256`` covers.
public struct AtlasPolicy: Decodable, Sendable, Equatable, Identifiable {
    public let key: String
    public let title: String
    public let display: AtlasPolicyDisplay
    public let required: Bool
    public let appliesTo: String
    public let position: Int
    public let versionId: String
    public let version: String
    public let contentMarkdown: String?
    public let contentHTML: String
    public let contentSHA256: String
    public let contentURL: String?
    public let summaryOfChanges: String?
    public let locale: String?
    public let publishedAt: Int64?
    public let effectiveAt: Int64?
    /// For a policy a held sign-in lists: `next_sign_in` or `grace`.
    public let reaccept: String?

    /// One entry per policy version.
    public var id: String { "\(key)@\(versionId)" }

    /// Whether there is anything to show.
    public var hasContent: Bool {
        !contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(contentMarkdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The document as blocks a view can lay out.
    public var document: [PolicyBlock] { PolicyHTML.blocks(html: contentHTML, markdown: contentMarkdown) }

    public init(
        key: String,
        title: String,
        display: AtlasPolicyDisplay = .checkbox,
        required: Bool = true,
        appliesTo: String = "sign_up",
        position: Int = 0,
        versionId: String,
        version: String = "",
        contentMarkdown: String? = nil,
        contentHTML: String = "",
        contentSHA256: String,
        contentURL: String? = nil,
        summaryOfChanges: String? = nil,
        locale: String? = nil,
        publishedAt: Int64? = nil,
        effectiveAt: Int64? = nil,
        reaccept: String? = nil
    ) {
        self.key = key
        self.title = title
        self.display = display
        self.required = required
        self.appliesTo = appliesTo
        self.position = position
        self.versionId = versionId
        self.version = version
        self.contentMarkdown = contentMarkdown
        self.contentHTML = contentHTML
        self.contentSHA256 = contentSHA256
        self.contentURL = contentURL
        self.summaryOfChanges = summaryOfChanges
        self.locale = locale
        self.publishedAt = publishedAt
        self.effectiveAt = effectiveAt
        self.reaccept = reaccept
    }

    /// A held sign-in's pending policy, without content (``AtlasClient/policies(resolving:locale:)`` fills it).
    public init(pending: PendingPolicy) {
        self.init(
            key: pending.policy, title: pending.title, display: pending.display, required: true,
            appliesTo: "sign_in_and_sign_up", versionId: pending.versionId, version: pending.version,
            contentSHA256: pending.contentSHA256, summaryOfChanges: pending.summaryOfChanges,
            reaccept: pending.reaccept
        )
    }

    enum CodingKeys: String, CodingKey {
        case key, policy, title, display, required, position, version, locale, reaccept
        case appliesTo = "applies_to"
        case versionId = "version_id"
        case contentMarkdown = "content_markdown"
        case contentHTML = "content_html"
        case contentSHA256 = "content_sha256"
        case contentURL = "content_url"
        case summaryOfChanges = "summary_of_changes"
        case publishedAt = "published_at"
        case effectiveAt = "effective_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .key) ?? c.decode(String.self, forKey: .policy)
        key = name
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        display = AtlasPolicyDisplay(wire: try c.decodeIfPresent(String.self, forKey: .display))
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        appliesTo = try c.decodeIfPresent(String.self, forKey: .appliesTo) ?? "sign_up"
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        versionId = try c.decode(String.self, forKey: .versionId)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        contentMarkdown = try c.decodeIfPresent(String.self, forKey: .contentMarkdown)
        contentHTML = try c.decodeIfPresent(String.self, forKey: .contentHTML) ?? ""
        contentSHA256 = try c.decode(String.self, forKey: .contentSHA256)
        contentURL = try c.decodeIfPresent(String.self, forKey: .contentURL)
        summaryOfChanges = try c.decodeIfPresent(String.self, forKey: .summaryOfChanges)
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        publishedAt = PolicyTime.decode(c, .publishedAt)
        effectiveAt = PolicyTime.decode(c, .effectiveAt)
        reaccept = try c.decodeIfPresent(String.self, forKey: .reaccept)
    }
}

/// Epoch-millisecond timestamps, tolerant of a number or an ISO-8601 string.
enum PolicyTime {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let n = try? c.decodeIfPresent(Int64.self, forKey: key) { return n }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return Int64(date.timeIntervalSince1970 * 1000) }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return Int64(date.timeIntervalSince1970 * 1000) }
        }
        return nil
    }
}

/// `GET /v1/client/policies`.
public struct AtlasPolicies: Decodable, Sendable, Equatable {
    public let policies: [AtlasPolicy]
    /// The legacy single legal checkbox (send `consent: true` on sign-up), when configured.
    public let legacyConsent: LegacyConsent?

    public struct LegacyConsent: Decodable, Sendable, Equatable {
        public let required: Bool
        public let termsURL: String?
        public let privacyURL: String?
        public init(required: Bool, termsURL: String? = nil, privacyURL: String? = nil) {
            self.required = required
            self.termsURL = termsURL
            self.privacyURL = privacyURL
        }
        enum CodingKeys: String, CodingKey {
            case required
            case termsURL = "terms_url"
            case privacyURL = "privacy_url"
        }
    }

    public init(policies: [AtlasPolicy], legacyConsent: LegacyConsent? = nil) {
        self.policies = policies
        self.legacyConsent = legacyConsent
    }

    enum CodingKeys: String, CodingKey {
        case policies = "data"
        case legacyConsent = "legacy_consent"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.decodeIfPresent([AtlasPolicy].self, forKey: .policies) ?? []
        policies = list.sorted { $0.position < $1.position }
        legacyConsent = try c.decodeIfPresent(LegacyConsent.self, forKey: .legacyConsent)
    }
}

/// A policy a held sign-in lists in `pending_policies`: what to accept, without the content.
public struct PendingPolicy: Decodable, Sendable, Equatable {
    public let policy: String
    public let policyId: String?
    public let title: String
    public let display: AtlasPolicyDisplay
    public let versionId: String
    public let version: String
    public let contentSHA256: String
    public let reaccept: String?
    public let summaryOfChanges: String?

    public init(
        policy: String, policyId: String? = nil, title: String, display: AtlasPolicyDisplay = .checkbox,
        versionId: String, version: String = "", contentSHA256: String,
        reaccept: String? = nil, summaryOfChanges: String? = nil
    ) {
        self.policy = policy
        self.policyId = policyId
        self.title = title
        self.display = display
        self.versionId = versionId
        self.version = version
        self.contentSHA256 = contentSHA256
        self.reaccept = reaccept
        self.summaryOfChanges = summaryOfChanges
    }

    enum CodingKeys: String, CodingKey {
        case policy, key, title, display, version, reaccept
        case policyId = "policy_id"
        case versionId = "version_id"
        case contentSHA256 = "content_sha256"
        case summaryOfChanges = "summary_of_changes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .policy) ?? c.decode(String.self, forKey: .key)
        policy = name
        policyId = try c.decodeIfPresent(String.self, forKey: .policyId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        display = AtlasPolicyDisplay(wire: try c.decodeIfPresent(String.self, forKey: .display))
        versionId = try c.decode(String.self, forKey: .versionId)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        contentSHA256 = try c.decode(String.self, forKey: .contentSHA256)
        reaccept = try c.decodeIfPresent(String.self, forKey: .reaccept)
        summaryOfChanges = try c.decodeIfPresent(String.self, forKey: .summaryOfChanges)
    }
}

/// One entry of `policy_acceptances`: what the user accepted and how they read it.
public struct PolicyAcceptance: Sendable, Equatable {
    public let policy: String
    public let versionId: String
    public let contentSHA256: String
    public let display: AtlasPolicyDisplay?
    /// Scroll mode: the user reached the end of the document (client-attested).
    public let scrolledToEnd: Bool?
    /// How long the document was open, in milliseconds (client-attested).
    public let viewMs: Int?
    public let locale: String?

    public init(
        policy: String, versionId: String, contentSHA256: String, display: AtlasPolicyDisplay? = nil,
        scrolledToEnd: Bool? = nil, viewMs: Int? = nil, locale: String? = nil
    ) {
        self.policy = policy
        self.versionId = versionId
        self.contentSHA256 = contentSHA256
        self.display = display
        self.scrolledToEnd = scrolledToEnd
        self.viewMs = viewMs
        self.locale = locale
    }

    /// The request-body object (`policy`, `version_id`, `content_sha256`, …).
    public var json: [String: Any] {
        var out: [String: Any] = ["policy": policy, "version_id": versionId, "content_sha256": contentSHA256]
        if let display { out["display"] = display.rawValue }
        if let scrolledToEnd { out["scrolled_to_end"] = scrolledToEnd }
        if let viewMs { out["view_ms"] = max(0, viewMs) }
        if let locale, !locale.isEmpty { out["locale"] = locale }
        return out
    }
}

/// Why a `POLICY_ACCEPTANCE_REQUIRED` refusal named a policy.
public enum PolicyProblemKind: String, Sendable, Equatable {
    case missing
    case staleVersion = "stale_version"
    case hashMismatch = "hash_mismatch"
    case scrollRequired = "scroll_required"
    case unknownVersion = "unknown_version"
    case unknownPolicy = "unknown_policy"
    case other
}

/// One element of `meta.policies` on a `POLICY_ACCEPTANCE_REQUIRED` refusal.
public struct PolicyProblem: Sendable, Equatable {
    public let policy: String
    public let title: String
    public let display: AtlasPolicyDisplay
    public let versionId: String?
    public let version: String?
    public let contentSHA256: String?
    public let summaryOfChanges: String?
    public let problem: PolicyProblemKind

    init?(json: JSONValue) {
        guard case let .object(o) = json, case let .string(name)? = o["policy"] else { return nil }
        func str(_ k: String) -> String? { if case let .string(s)? = o[k] { return s } else { return nil } }
        policy = name
        title = str("title") ?? name
        display = AtlasPolicyDisplay(wire: str("display"))
        versionId = str("version_id")
        version = str("version")
        contentSHA256 = str("content_sha256")
        summaryOfChanges = str("summary_of_changes")
        problem = PolicyProblemKind(rawValue: str("problem") ?? "") ?? .other
    }
}

/// One policy of `GET /v1/client/me/policies`: the signed-in user's standing.
public struct PolicyStanding: Decodable, Sendable, Equatable {
    public let policy: String
    public let policyId: String?
    public let title: String
    public let display: AtlasPolicyDisplay
    public let required: Bool
    public let reaccept: String?
    public let currentVersionId: String?
    public let currentVersion: String?
    public let contentSHA256: String?
    public let summaryOfChanges: String?
    public let acceptedVersionId: String?
    public let acceptedVersion: String?
    public let acceptedAt: Int64?
    /// The current version is not accepted yet.
    public let needsReaccept: Bool
    /// The next sign-in stops for this policy.
    public let blocking: Bool
    /// A grace window runs until then: show a banner, sign-in still works.
    public let graceEndsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case policy, title, display, required, reaccept, blocking
        case policyId = "policy_id"
        case currentVersionId = "current_version_id"
        case currentVersion = "current_version"
        case contentSHA256 = "content_sha256"
        case summaryOfChanges = "summary_of_changes"
        case acceptedVersionId = "accepted_version_id"
        case acceptedVersion = "accepted_version"
        case acceptedAt = "accepted_at"
        case needsReaccept = "needs_reaccept"
        case graceEndsAt = "grace_ends_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decode(String.self, forKey: .policy)
        policyId = try c.decodeIfPresent(String.self, forKey: .policyId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? policy
        display = AtlasPolicyDisplay(wire: try c.decodeIfPresent(String.self, forKey: .display))
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        reaccept = try c.decodeIfPresent(String.self, forKey: .reaccept)
        currentVersionId = try c.decodeIfPresent(String.self, forKey: .currentVersionId)
        currentVersion = try c.decodeIfPresent(String.self, forKey: .currentVersion)
        contentSHA256 = try c.decodeIfPresent(String.self, forKey: .contentSHA256)
        summaryOfChanges = try c.decodeIfPresent(String.self, forKey: .summaryOfChanges)
        acceptedVersionId = try c.decodeIfPresent(String.self, forKey: .acceptedVersionId)
        acceptedVersion = try c.decodeIfPresent(String.self, forKey: .acceptedVersion)
        acceptedAt = PolicyTime.decode(c, .acceptedAt)
        needsReaccept = try c.decodeIfPresent(Bool.self, forKey: .needsReaccept) ?? false
        blocking = try c.decodeIfPresent(Bool.self, forKey: .blocking) ?? false
        graceEndsAt = PolicyTime.decode(c, .graceEndsAt)
    }
}

/// `GET /v1/client/me/policies`.
public struct MyPolicies: Decodable, Sendable, Equatable {
    public let standings: [PolicyStanding]
    /// A required policy's current version is not accepted (banner time).
    public let needsAcceptance: Bool
    /// The next sign-in will stop for at least one policy.
    public let blocking: Bool

    /// The policies that still need accepting.
    public var pending: [PolicyStanding] { standings.filter { $0.needsReaccept } }

    enum CodingKeys: String, CodingKey {
        case standings = "data"
        case needsAcceptance = "needs_acceptance"
        case blocking
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        standings = try c.decodeIfPresent([PolicyStanding].self, forKey: .standings) ?? []
        needsAcceptance = try c.decodeIfPresent(Bool.self, forKey: .needsAcceptance) ?? false
        blocking = try c.decodeIfPresent(Bool.self, forKey: .blocking) ?? false
    }
}

/// The reply to `POST /v1/client/me/policies/accept`: the user's standing afterwards.
public struct AcceptedPolicies: Decodable, Sendable, Equatable {
    public let standings: [PolicyStanding]
    enum CodingKeys: String, CodingKey { case standings }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        standings = try c.decodeIfPresent([PolicyStanding].self, forKey: .standings) ?? []
    }
}

// MARK: - request bodies

/// The `accept_policies` request body: the acceptances plus the proof of the held
/// attempt — the one-time `policy_acceptance_token`, else the attempt's
/// `poll_secret` (a magic-link or QR tab). The attempt id alone is never enough.
func acceptPoliciesBody(
    acceptances: [PolicyAcceptance],
    policyToken: String?,
    pollSecret: String?
) -> [String: Any] {
    var body: [String: Any] = ["policy_acceptances": acceptances.map(\.json)]
    if let policyToken, !policyToken.isEmpty {
        body["policy_acceptance_token"] = policyToken
    } else if let pollSecret, !pollSecret.isEmpty {
        body["poll_secret"] = pollSecret
    }
    return body
}

/// Per-policy reading evidence for ``buildPolicyAcceptances(_:evidence:locale:)``.
public struct PolicyEvidence: Sendable, Equatable {
    public var scrolledToEnd: Bool?
    public var viewMs: Int?
    public init(scrolledToEnd: Bool? = nil, viewMs: Int? = nil) {
        self.scrolledToEnd = scrolledToEnd
        self.viewMs = viewMs
    }
}

/// Turn the policies the user saw and agreed to into `policy_acceptances`.
public func buildPolicyAcceptances(
    _ shown: [AtlasPolicy],
    evidence: [String: PolicyEvidence] = [:],
    locale: String? = nil
) -> [PolicyAcceptance] {
    shown.map { p in
        let e = evidence[p.key] ?? PolicyEvidence()
        return PolicyAcceptance(
            policy: p.key, versionId: p.versionId, contentSHA256: p.contentSHA256, display: p.display,
            scrolledToEnd: e.scrolledToEnd, viewMs: e.viewMs.map { max(0, $0) }, locale: locale
        )
    }
}

// MARK: - acceptance state

/// What the user has done on a set of policies: checkboxes ticked, documents read
/// to the end, how long each was open. A value type the SwiftUI model wraps and
/// tests drive directly; the clock is passed in so it is deterministic.
public struct PolicyAcceptanceState: Sendable, Equatable {
    public private(set) var policies: [AtlasPolicy]
    private var ticked: Set<String> = []
    private var scrolled: Set<String> = []
    private var viewMs: [String: Int] = [:]
    private var openedAt: [String: Date] = [:]

    public init(policies: [AtlasPolicy] = []) {
        self.policies = policies
    }

    /// Replace the policies (e.g. after a 422 reload). Ticks and reading evidence
    /// survive for a policy whose version did not change.
    public mutating func setPolicies(_ fresh: [AtlasPolicy]) {
        let ids = Set(fresh.map(\.id))
        policies = fresh
        ticked = ticked.intersection(ids)
        scrolled = scrolled.intersection(ids)
        viewMs = viewMs.filter { ids.contains($0.key) }
        openedAt = openedAt.filter { ids.contains($0.key) }
    }

    public var checkboxPolicies: [AtlasPolicy] { policies.filter { $0.display == .checkbox } }
    public var scrollPolicies: [AtlasPolicy] { policies.filter { $0.display == .scroll } }
    public var linkPolicies: [AtlasPolicy] { policies.filter { $0.display == .link } }

    public func isTicked(_ policy: AtlasPolicy) -> Bool { ticked.contains(policy.id) }

    public mutating func setTicked(_ policy: AtlasPolicy, _ on: Bool) {
        if on { ticked.insert(policy.id) } else { ticked.remove(policy.id) }
    }

    /// Tick or untick every checkbox policy at once (the combined checkbox).
    public mutating func setAllCheckboxes(_ on: Bool) {
        for p in checkboxPolicies { setTicked(p, on) }
    }

    /// Whether every checkbox policy is ticked (the combined checkbox's state).
    public var allCheckboxesTicked: Bool {
        let boxes = checkboxPolicies
        return !boxes.isEmpty && boxes.allSatisfy(isTicked)
    }

    /// The document reached its end (or fits on screen) while open.
    public mutating func markScrolledToEnd(_ policy: AtlasPolicy) { scrolled.insert(policy.id) }
    public func hasScrolledToEnd(_ policy: AtlasPolicy) -> Bool { scrolled.contains(policy.id) }

    /// The user accepted a scroll-mode document in its sheet.
    public mutating func acceptScroll(_ policy: AtlasPolicy) {
        scrolled.insert(policy.id)
        ticked.insert(policy.id)
    }

    /// The document opened (viewer or sheet).
    public mutating func beginReading(_ policy: AtlasPolicy, at now: Date) {
        if openedAt[policy.id] == nil { openedAt[policy.id] = now }
    }

    /// The document closed: add the time it was open to the policy's `view_ms`.
    public mutating func endReading(_ policy: AtlasPolicy, at now: Date) {
        guard let start = openedAt.removeValue(forKey: policy.id) else { return }
        let ms = Int(max(0, now.timeIntervalSince(start)) * 1000)
        viewMs[policy.id, default: 0] += ms
    }

    public func viewDuration(_ policy: AtlasPolicy) -> Int { viewMs[policy.id] ?? 0 }

    /// Required scroll-mode policies not yet accepted: the sheets still to show.
    public var pendingScroll: [AtlasPolicy] {
        scrollPolicies.filter { $0.required && !isTicked($0) }
    }

    /// The required policies still unaccepted, scroll ones included.
    public var missingRequired: [AtlasPolicy] {
        policies.filter { $0.required && $0.display != .link && !isTicked($0) }
    }

    /// Whether the submit button may be enabled: every required checkbox is ticked.
    /// Scroll-mode documents are shown on submit, so they do not hold it back.
    public var canSubmit: Bool {
        checkboxPolicies.allSatisfy { !$0.required || isTicked($0) }
    }

    /// Whether ``build(locale:)`` would satisfy every required policy.
    public var isComplete: Bool { missingRequired.isEmpty }

    /// The `policy_acceptances` to send: ticked checkboxes, accepted scroll
    /// documents, and every clickwrap policy (submitting accepts those).
    public func build(locale: String? = nil) -> [PolicyAcceptance] {
        let accepted = policies.filter { $0.display == .link || isTicked($0) }
        var evidence: [String: PolicyEvidence] = [:]
        for p in accepted {
            var e = PolicyEvidence()
            if p.display == .scroll || scrolled.contains(p.id) { e.scrolledToEnd = scrolled.contains(p.id) }
            let ms = viewMs[p.id] ?? 0
            if ms > 0 { e.viewMs = ms }
            evidence[p.key] = e
        }
        return buildPolicyAcceptances(accepted, evidence: evidence, locale: locale)
    }
}

/// The scroll-to-end decision, kept pure so it can be tested off-screen.
public enum PolicyScroll {
    /// Whether the end marker is inside the viewport: its bottom edge (in the
    /// scroll view's own coordinates) is at or above the viewport's bottom edge,
    /// within `tolerance` points. A document shorter than the viewport therefore
    /// counts as read at once.
    public static func reachedEnd(endMaxY: Double, viewportHeight: Double, tolerance: Double = 2) -> Bool {
        guard viewportHeight > 0, endMaxY.isFinite else { return false }
        return endMaxY <= viewportHeight + tolerance
    }
}

// MARK: - sanitized HTML reader

/// An inline stretch of a policy paragraph with its styling.
public struct PolicyRun: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    /// An `http`, `https`, `mailto` or `tel` link target; nothing else is kept.
    public var link: String?

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.link = link
    }
}

public enum PolicyBlockKind: Sendable, Equatable {
    case paragraph
    case heading(Int)
    /// A list item with its marker ("•" or "1.").
    case listItem(marker: String)
    case quote
    case preformatted
    case rule
}

/// A block of a policy document.
public struct PolicyBlock: Sendable, Equatable {
    public var kind: PolicyBlockKind
    public var runs: [PolicyRun]
    /// List nesting depth (0 for the outermost list and non-list blocks).
    public var indent: Int

    public init(kind: PolicyBlockKind, runs: [PolicyRun] = [], indent: Int = 0) {
        self.kind = kind
        self.runs = runs
        self.indent = indent
    }

    public var plainText: String { runs.map(\.text).joined() }
}

/// Reads the sanitized HTML Atlas serves (paragraphs, headings, lists, links,
/// emphasis, code, quotes, rules, tables) into ``PolicyBlock``s — no web view, so
/// it works on tvOS and watchOS. Anything it does not know is read as its text;
/// `script` and `style` content is dropped, and only http(s), mailto and tel
/// links are kept (defence in depth: the server sanitized the HTML already).
public enum PolicyHTML {
    /// The document: the HTML, or when there is none the markdown as plain paragraphs.
    public static func blocks(html: String, markdown: String?) -> [PolicyBlock] {
        if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return parse(html) }
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { PolicyBlock(kind: .paragraph, runs: [PolicyRun(text: $0)]) }
    }

    public static func parse(_ html: String) -> [PolicyBlock] {
        var reader = Reader(Array(html.unicodeScalars))
        return reader.run()
    }

    static func safeLink(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for scheme in ["http://", "https://", "mailto:", "tel:"] where lower.hasPrefix(scheme) { return trimmed }
        return nil
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "copy": "\u{00A9}",
            "reg": "\u{00AE}", "trade": "\u{2122}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
            "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bull": "\u{2022}", "middot": "\u{00B7}",
            "sect": "\u{00A7}", "para": "\u{00B6}",
        ]
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "&", let semi = chars[i...].prefix(12).firstIndex(of: ";") {
                let body = String(chars[(i + 1)..<semi])
                var replacement: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    if let code = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(code) { replacement = String(Character(u)) }
                } else if body.hasPrefix("#") {
                    if let code = UInt32(body.dropFirst()), let u = Unicode.Scalar(code) { replacement = String(Character(u)) }
                } else {
                    replacement = named[body.lowercased()]
                }
                if let replacement {
                    out += replacement
                    i = semi + 1
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    private struct Reader {
        let src: [Unicode.Scalar]
        var pos = 0
        var blocks: [PolicyBlock] = []
        var runs: [PolicyRun] = []
        var kind: PolicyBlockKind = .paragraph
        var bold = 0, italic = 0, code = 0, pre = 0, quote = 0, skip = 0
        var links: [String?] = []
        var lists: [(ordered: Bool, n: Int)] = []

        init(_ src: [Unicode.Scalar]) { self.src = src }

        mutating func run() -> [PolicyBlock] {
            var text = ""
            while pos < src.count {
                let c = src[pos]
                if c == "<" {
                    if let next = tagEnd() {
                        flushText(&text)
                        handleTag(String(String.UnicodeScalarView(src[(pos + 1)..<next])))
                        pos = next + 1
                        continue
                    }
                }
                text.unicodeScalars.append(c)
                pos += 1
            }
            flushText(&text)
            flush()
            return blocks
        }

        /// Index of the `>` that closes the tag starting at `pos`, honouring quotes;
        /// nil when `<` is not a tag (a stray less-than sign).
        func tagEnd() -> Int? {
            var i = pos + 1
            guard i < src.count else { return nil }
            let first = src[i]
            let isLetter = (first.value >= 65 && first.value <= 90) || (first.value >= 97 && first.value <= 122)
            guard isLetter || first == "/" || first == "!" else { return nil }
            if first == "!" {
                // A comment ends at "-->", anything else at ">".
                if i + 2 < src.count, src[i + 1] == "-", src[i + 2] == "-" {
                    var j = i + 3
                    while j + 2 < src.count {
                        if src[j] == "-", src[j + 1] == "-", src[j + 2] == ">" { return j + 2 }
                        j += 1
                    }
                    return src.count - 1
                }
            }
            var quoteChar: Unicode.Scalar?
            while i < src.count {
                let c = src[i]
                if let q = quoteChar {
                    if c == q { quoteChar = nil }
                } else if c == "\"" || c == "'" {
                    quoteChar = c
                } else if c == ">" {
                    return i
                }
                i += 1
            }
            return nil
        }

        mutating func handleTag(_ raw: String) {
            if raw.hasPrefix("!") { return }
            var body = raw
            let closing = body.hasPrefix("/")
            if closing { body.removeFirst() }
            if body.hasSuffix("/") { body.removeLast() }
            let name = String(body.prefix { !$0.isWhitespace }).lowercased()
            let attrs = String(body.dropFirst(name.count))

            if skip > 0 {
                if closing, name == "script" || name == "style" { skip -= 1 }
                return
            }
            if !closing, name == "script" || name == "style" { skip += 1; return }

            switch name {
            case "p", "div", "section", "article", "header", "footer", "tr", "table", "thead", "tbody", "ul", "ol", "dl", "dt", "dd", "figure":
                flush()
                if name == "ul" || name == "ol" {
                    if closing { if !lists.isEmpty { lists.removeLast() } } else { lists.append((name == "ol", 0)) }
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !closing { kind = .heading(Int(String(name.last!)) ?? 3) }
            case "li":
                flush()
                if !closing {
                    if lists.isEmpty { lists.append((false, 0)) }
                    lists[lists.count - 1].n += 1
                    let top = lists[lists.count - 1]
                    kind = .listItem(marker: top.ordered ? "\(top.n)." : "\u{2022}")
                }
            case "blockquote":
                flush()
                if closing { quote = max(0, quote - 1) } else { quote += 1 }
            case "pre":
                flush()
                if closing { pre = max(0, pre - 1) } else { pre += 1; kind = .preformatted }
            case "br":
                if !closing { runs.append(styled("\n")) }
            case "hr":
                flush()
                blocks.append(PolicyBlock(kind: .rule))
            case "strong", "b", "th":
                bold = max(0, bold + (closing ? -1 : 1))
                if name == "th" || name == "td" { cellBreak(closing) }
            case "em", "i", "cite":
                italic = max(0, italic + (closing ? -1 : 1))
            case "code", "kbd", "samp", "tt":
                code = max(0, code + (closing ? -1 : 1))
            case "td":
                cellBreak(closing)
            case "a":
                if closing {
                    if !links.isEmpty { links.removeLast() }
                } else {
                    links.append(PolicyHTML.safeLink(attribute("href", in: attrs)))
                }
            default:
                break
            }
        }

        mutating func cellBreak(_ closing: Bool) {
            if closing { runs.append(styled(" ")) }
        }

        func attribute(_ name: String, in attrs: String) -> String? {
            let lower = attrs.lowercased()
            guard let r = lower.range(of: name + "=") else { return nil }
            let rest = attrs[r.upperBound...]
            guard let first = rest.first else { return nil }
            if first == "\"" || first == "'" {
                let tail = rest.dropFirst()
                guard let end = tail.firstIndex(of: first) else { return nil }
                return PolicyHTML.decodeEntities(String(tail[..<end]))
            }
            return PolicyHTML.decodeEntities(String(rest.prefix { !$0.isWhitespace }))
        }

        func styled(_ text: String) -> PolicyRun {
            PolicyRun(text: text, bold: bold > 0, italic: italic > 0, code: code > 0, link: links.last ?? nil)
        }

        mutating func flushText(_ text: inout String) {
            defer { text = "" }
            guard skip == 0, !text.isEmpty else { return }
            var decoded = PolicyHTML.decodeEntities(text)
            if pre == 0 {
                decoded = collapseWhitespace(decoded)
                if decoded == " " || decoded.isEmpty, runs.isEmpty { return }
                if decoded.hasPrefix(" "), let last = runs.last, last.text.hasSuffix(" ") || last.text.hasSuffix("\n") {
                    decoded.removeFirst()
                }
                if decoded.hasPrefix(" "), runs.isEmpty { decoded.removeFirst() }
            }
            guard !decoded.isEmpty else { return }
            runs.append(styled(decoded))
        }

        func collapseWhitespace(_ s: String) -> String {
            var out = ""
            var lastSpace = false
            for ch in s {
                if ch.isWhitespace {
                    if !lastSpace { out.append(" ") }
                    lastSpace = true
                } else {
                    out.append(ch)
                    lastSpace = false
                }
            }
            return out
        }

        mutating func flush() {
            defer { runs = []; kind = .paragraph }
            var trimmed = runs
            if kind != .preformatted {
                while let first = trimmed.first, first.text.allSatisfy({ $0.isWhitespace }) { trimmed.removeFirst() }
                while let last = trimmed.last, last.text.allSatisfy({ $0.isWhitespace }) { trimmed.removeLast() }
                if !trimmed.isEmpty {
                    trimmed[0].text = String(trimmed[0].text.drop { $0.isWhitespace })
                    let end = trimmed.count - 1
                    while let ch = trimmed[end].text.last, ch.isWhitespace { trimmed[end].text.removeLast() }
                }
            } else {
                while let last = trimmed.last, last.text.allSatisfy({ $0 == "\n" }) { trimmed.removeLast() }
            }
            guard !trimmed.isEmpty else { return }
            var k = kind
            if k == .paragraph, quote > 0 { k = .quote }
            var indent = 0
            if case .listItem = k { indent = max(0, lists.count - 1) }
            blocks.append(PolicyBlock(kind: k, runs: trimmed, indent: indent))
        }
    }
}

// MARK: - redirect callbacks

/// What Atlas appends to an OAuth / SSO callback URL: `__atlas_attempt`, plus
/// `__atlas_ticket` when the sign-in completed, or `__atlas_status` (and, for
/// `needs_policy_acceptance`, the one-time `__atlas_policy_token`) when it stopped.
public struct AtlasRedirectResult: Sendable, Equatable {
    public let attemptId: String
    public let ticket: String?
    public let status: String?
    /// With `needs_policy_acceptance`: the proof ``SignInFlow/acceptPolicies(_:pollSecret:)`` sends.
    public let policyToken: String?

    /// Nil unless `url` is an Atlas redirect (an attempt id plus a ticket or a status).
    public init?(url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let attempt = value("__atlas_attempt") else { return nil }
        let ticket = value("__atlas_ticket")
        let status = value("__atlas_status")
        guard ticket != nil || status != nil else { return nil }
        attemptId = attempt
        self.ticket = ticket
        self.status = status
        policyToken = status == SignInStatus.needsPolicyAcceptance.rawValue ? value("__atlas_policy_token") : nil
    }
}

/// How a redirect callback ended.
public enum AtlasRedirectOutcome: Sendable {
    /// The ticket was exchanged; the session is persisted.
    case signedIn(AtlasUser)
    /// The sign-in stopped (a policy to accept, a second factor, …). Drive it with the
    /// returned flow; for `needs_policy_acceptance` it already holds the one-time token.
    case needsNextStep(SignInFlow)
}

// MARK: - client calls

extension AtlasClient {
    /// The current version of every policy (`GET /v1/client/policies`), ready to
    /// render: `contentHTML` is sanitized and `contentSHA256` is its hash.
    public func policies(locale: String? = nil) async throws -> AtlasPolicies {
        var path = "/v1/client/policies"
        if let locale, !locale.isEmpty,
           let q = locale.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?locale=\(q)"
        }
        let (data, response) = try await sendJSON("GET", path, json: nil, refreshCookie: nil)
        try throwIfError(status: response.statusCode, data: data)
        return try decode(AtlasPolicies.self, from: data)
    }

    /// The policies a held sign-in lists, with their content. A held attempt
    /// carries the list without the documents; they are fetched here and matched by
    /// key. With an empty `pending` (a redirect carries the attempt, not its list)
    /// every required policy is returned and the server checks each acceptance.
    /// Every policy of a held sign-in is required of the user.
    public func policies(resolving pending: [PendingPolicy], locale: String? = nil) async throws -> [AtlasPolicy] {
        let all = try await policies(locale: locale).policies
        if pending.isEmpty { return all.filter { $0.required } }
        return pending.map { p in
            guard let full = all.first(where: { $0.key == p.policy }) else { return AtlasPolicy(pending: p) }
            return AtlasPolicy(
                key: p.policy, title: p.title, display: p.display, required: true, appliesTo: full.appliesTo,
                position: full.position, versionId: p.versionId, version: p.version.isEmpty ? full.version : p.version,
                contentMarkdown: full.versionId == p.versionId ? full.contentMarkdown : nil,
                contentHTML: full.versionId == p.versionId ? full.contentHTML : "",
                contentSHA256: p.contentSHA256, contentURL: full.contentURL,
                summaryOfChanges: p.summaryOfChanges ?? full.summaryOfChanges, locale: full.locale,
                publishedAt: full.publishedAt, effectiveAt: full.effectiveAt, reaccept: p.reaccept
            )
        }
    }

    /// The signed-in user's standing on every policy (`GET /v1/client/me/policies`).
    public func myPolicies() async throws -> MyPolicies {
        try await authedDecode(MyPolicies.self, "GET", "/v1/client/me/policies")
    }

    /// Accept policies from inside the app, e.g. from a banner during a grace
    /// window (`POST /v1/client/me/policies/accept`). Returns the standing afterwards.
    @discardableResult
    public func acceptMyPolicies(_ acceptances: [PolicyAcceptance]) async throws -> AcceptedPolicies {
        try await authedDecode(
            AcceptedPolicies.self, "POST", "/v1/client/me/policies/accept",
            json: ["policy_acceptances": acceptances.map(\.json)]
        )
    }

    /// `POST /v1/client/sign_ins/:id/accept_policies` — continue an attempt held at
    /// `needs_policy_acceptance` (any kind: sign-in, social/SSO sign-up, password
    /// reset). Sends the one-time token, else the poll secret; the id alone is not
    /// accepted. The reply is the attempt view (with a `ticket` on completion).
    func acceptAttemptPolicies(
        attemptId: String,
        acceptances: [PolicyAcceptance],
        policyToken: String?,
        pollSecret: String?
    ) async throws -> SignInAttempt {
        let body = acceptPoliciesBody(acceptances: acceptances, policyToken: policyToken, pollSecret: pollSecret)
        let (data, response) = try await sendJSON(
            "POST", "/v1/client/sign_ins/\(attemptId)/accept_policies", json: body, refreshCookie: nil
        )
        try throwIfError(status: response.statusCode, data: data)
        return try decode(SignInAttempt.self, from: data)
    }

    /// Finish an OAuth / SSO callback: read `__atlas_attempt`, `__atlas_ticket`,
    /// `__atlas_status` and `__atlas_policy_token` off `url` (the
    /// `ASWebAuthenticationSession` callback), exchange the ticket, or hand back a
    /// flow seeded at the stopped attempt — for `needs_policy_acceptance` it keeps
    /// the one-time token, which exists only in this URL. Nil when `url` is not an
    /// Atlas redirect.
    public func completeRedirect(_ url: URL) async throws -> AtlasRedirectOutcome? {
        guard let result = AtlasRedirectResult(url: url) else { return nil }
        if let ticket = result.ticket {
            try await exchangeTicket(attemptId: result.attemptId, ticket: ticket)
            return .signedIn(try await currentUser())
        }
        let attempt = SignInAttempt(
            id: result.attemptId,
            status: result.status ?? SignInStatus.needsIdentifier.rawValue,
            policyAcceptanceToken: result.policyToken
        )
        return .needsNextStep(SignInFlow(client: self, attempt: attempt))
    }
}

/// Thrown by a sign-in that the server held for policy acceptance after the
/// credential was already verified (a passkey sign-in): continue with ``flow``.
public struct AtlasPolicyAcceptanceNeeded: Error, Sendable {
    public let flow: SignInFlow
    public init(flow: SignInFlow) { self.flow = flow }
}

extension AtlasPolicyAcceptanceNeeded: LocalizedError {
    public var errorDescription: String? { "Accept the required policies to finish signing in." }
}

// MARK: - wording

/// The English wording the prebuilt policy surfaces use (and a custom UI can reuse).
public enum PolicyText {
    /// "A", "A and B", "A, B and C".
    public static func join(_ titles: [String]) -> String {
        switch titles.count {
        case 0: return ""
        case 1: return titles[0]
        default: return titles.dropLast().joined(separator: ", ") + " and " + titles[titles.count - 1]
        }
    }

    public static func agree(_ titles: [String]) -> String { "I agree to the \(join(titles))" }
    public static func clickwrap(_ titles: [String]) -> String { "By continuing you agree to the \(join(titles))." }
    public static func declined(_ title: String) -> String { "You need to accept the \(title) to continue." }
    public static let scrollHint = "Scroll to the end to accept"
    public static let pendingTitle = "Accept to continue"
    public static let pendingIntro = "Please accept the following to continue."
}
