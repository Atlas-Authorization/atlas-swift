// Policy acceptance in SwiftUI, native on every Apple platform: a checkbox row
// with an in-app document viewer, the unskippable scroll sheet, clickwrap text.
// The sanitized HTML is read into blocks (`PolicyHTML`) and drawn as attributed
// `Text`: no web view, so it works on tvOS and watchOS alike.
//
// iOS, iPadOS, macOS, visionOS: the policy names in the sentence are links that
// open the viewer. tvOS and watchOS: text links are not focusable or tappable,
// so each policy gets its own "Read" button, and the document blocks take focus
// (tvOS) so the remote scrolls them; watchOS scrolls with the digital crown.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - model

/// What a policy screen binds to: the policies, the user's ticks and reading
/// evidence (``PolicyAcceptanceState``), and the sheets on screen.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public final class PolicyAcceptanceModel: ObservableObject {
    @Published public private(set) var state: PolicyAcceptanceState
    /// Whether the policies have been loaded (a screen shows a spinner before).
    @Published public private(set) var isLoaded: Bool
    /// The document open in the viewer (checkbox and clickwrap policies).
    @Published public var viewing: AtlasPolicy?
    /// The unskippable document on screen (scroll policies).
    @Published public var scrollSheet: AtlasPolicy?
    /// Why the user cannot continue (a declined policy), or nil.
    @Published public var message: String?
    /// One checkbox for all checkbox-mode policies (the default) or one each.
    public var combined: Bool
    /// Called when the user declines a scroll document.
    public var onDecline: ((AtlasPolicy) -> Void)?

    private let now: () -> Date
    private var finish: (() -> Void)?
    private var awaitingDismiss = false

    public init(
        policies: [AtlasPolicy]? = nil,
        combined: Bool = true,
        now: @escaping () -> Date = { Date() }
    ) {
        self.state = PolicyAcceptanceState(policies: policies ?? [])
        self.isLoaded = policies != nil
        self.combined = combined
        self.now = now
    }

    /// Set the policies to show; ticks and evidence survive for unchanged versions.
    public func load(_ policies: [AtlasPolicy]) {
        state.setPolicies(policies)
        isLoaded = true
    }

    /// Forget everything (a new attempt).
    public func reset() {
        state = PolicyAcceptanceState()
        isLoaded = false
        viewing = nil
        scrollSheet = nil
        message = nil
        finish = nil
        awaitingDismiss = false
    }

    public func setTicked(_ policy: AtlasPolicy, _ on: Bool) {
        state.setTicked(policy, on)
        message = nil
    }

    public func setAllCheckboxes(_ on: Bool) {
        state.setAllCheckboxes(on)
        message = nil
    }

    /// Open a document in the in-app viewer.
    public func open(_ policy: AtlasPolicy) {
        state.beginReading(policy, at: now())
        viewing = policy
    }

    public func closeViewer() {
        if let p = viewing { state.endReading(p, at: now()) }
        viewing = nil
    }

    /// The document on screen was scrolled to its end (or fits).
    public func markReachedEnd(_ policy: AtlasPolicy) {
        guard !state.hasScrolledToEnd(policy) else { return }
        state.markScrolledToEnd(policy)
    }

    func endReading(_ policy: AtlasPolicy) { state.endReading(policy, at: now()) }

    /// Submit: show each required scroll document in turn, then call `proceed` with
    /// the `policy_acceptances` to send. Declining a document stops here.
    public func beginSubmit(locale: String? = nil, then proceed: @escaping ([PolicyAcceptance]) -> Void) {
        message = nil
        finish = { [weak self] in
            guard let self else { return }
            proceed(self.state.build(locale: locale))
        }
        advance()
    }

    private func advance() {
        if let next = state.pendingScroll.first {
            state.beginReading(next, at: now())
            scrollSheet = next
        } else if let go = finish {
            finish = nil
            go()
        }
    }

    /// The user accepted the scroll document on screen (its Accept button is only
    /// enabled once the end was seen).
    func acceptScroll() {
        guard let policy = scrollSheet else { return }
        state.endReading(policy, at: now())
        state.acceptScroll(policy)
        awaitingDismiss = true
        scrollSheet = nil
        // `onDismiss` continues; if the platform never reports it, continue anyway.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.scrollSheetDismissed()
        }
    }

    func scrollSheetDismissed() {
        guard awaitingDismiss else { return }
        awaitingDismiss = false
        advance()
    }

    /// The user declined the scroll document on screen: the submit is cancelled.
    func decline(_ policy: AtlasPolicy) {
        state.endReading(policy, at: now())
        scrollSheet = nil
        finish = nil
        awaitingDismiss = false
        message = PolicyText.declined(policy.title)
        onDecline?(policy)
    }
}

// MARK: - document rendering

/// A block's runs as one attributed string (bold, italic, code, links).
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
func atlasAttributed(_ runs: [PolicyRun], allBold: Bool = false) -> AttributedString {
    var out = AttributedString()
    for run in runs {
        var piece = AttributedString(run.text)
        var intent: InlinePresentationIntent = []
        if run.bold || allBold { intent.insert(.stronglyEmphasized) }
        if run.italic { intent.insert(.emphasized) }
        if run.code { intent.insert(.code) }
        if !intent.isEmpty { piece.inlinePresentationIntent = intent }
        if let link = run.link, let url = URL(string: link) { piece.link = url }
        out += piece
    }
    return out
}

/// A policy document as text, laid out block by block.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasPolicyDocument: View {
    let blocks: [PolicyBlock]
    let style: AtlasStyle?
    @Environment(\.colorScheme) private var scheme

    private var textColor: Color? { style.map { $0.palette.color(.text) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
                    #if os(tvOS)
                    .focusable()
                    #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodyFont: Font {
        if let style { return style.bodyFont }
        #if os(watchOS)
        return .footnote
        #else
        return .body
        #endif
    }

    private func headingFont(_ level: Int) -> Font {
        if let style { return level <= 2 ? style.headingFont : style.bodyFont.weight(.semibold) }
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    @ViewBuilder private func blockView(_ block: PolicyBlock) -> some View {
        switch block.kind {
        case let .heading(level):
            Text(atlasAttributed(block.runs, allBold: true))
                .font(headingFont(level))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case let .listItem(marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(bodyFont).foregroundColor(textColor)
                Text(atlasAttributed(block.runs)).font(bodyFont).foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(block.indent) * 16)
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(atlasAttributed(block.runs)).font(bodyFont).foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .preformatted:
            Text(block.plainText)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        case .paragraph:
            Text(atlasAttributed(block.runs)).font(bodyFont).foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The bottom edge of the document's end marker, in the scroll view's coordinates.
private struct AtlasPolicyEndKey: PreferenceKey {
    static var defaultValue: CGFloat { .infinity }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A scrolling policy document that reports when its end is on screen (or the whole
/// text fits). On watchOS the `footer` (the Accept / Decline buttons) scrolls with
/// the text, so the digital crown reaches it; elsewhere it is empty.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasPolicyScroller<Footer: View>: View {
    let policy: AtlasPolicy
    let style: AtlasStyle?
    let onReachedEnd: () -> Void
    let footer: Footer

    init(policy: AtlasPolicy, style: AtlasStyle?, onReachedEnd: @escaping () -> Void, @ViewBuilder footer: () -> Footer) {
        self.policy = policy
        self.style = style
        self.onReachedEnd = onReachedEnd
        self.footer = footer()
    }

    private static var space: String { "atlas-policy-scroll" }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = policy.summaryOfChanges, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What changed").font(.subheadline.weight(.semibold))
                            Text(summary).font(.footnote)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(8)
                    }
                    if policy.hasContent {
                        AtlasPolicyDocument(blocks: policy.document, style: style)
                    } else {
                        Text("This document could not be loaded.").font(.footnote).foregroundColor(.secondary)
                    }
                    Color.clear
                        .frame(height: 1)
                        .background(GeometryReader { marker in
                            Color.clear.preference(
                                key: AtlasPolicyEndKey.self,
                                value: marker.frame(in: .named(Self.space)).maxY
                            )
                        })
                    footer
                }
                .padding(.vertical, 2)
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(AtlasPolicyEndKey.self) { endY in
                if PolicyScroll.reachedEnd(endMaxY: Double(endY), viewportHeight: Double(outer.size.height)) {
                    onReachedEnd()
                }
            }
        }
    }
}

// MARK: - sheets

/// The unskippable document: no close button, no swipe or Esc dismissal. Accept
/// enables once the end of the text is on screen (or the text fits); Decline
/// cancels what the user was doing.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasPolicyScrollSheet: View {
    @ObservedObject var model: PolicyAcceptanceModel
    let policy: AtlasPolicy
    let style: AtlasStyle?
    @State private var reached = false

    var body: some View {
        content
            .interactiveDismissDisabled(true)
            .onAppear { reached = model.state.hasScrolledToEnd(policy) }
            .onDisappear { model.endReading(policy) }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
            #endif
    }

    private func end() {
        reached = true
        model.markReachedEnd(policy)
    }

    private var titleView: some View {
        Text(policy.title)
            .font(style?.headingFont ?? .headline)
            .foregroundColor(style.map { $0.palette.color(.text) })
            .accessibilityAddTraits(.isHeader)
    }

    private var hint: some View {
        Text(PolicyText.scrollHint)
            .font(.footnote)
            .foregroundColor(.secondary)
            .opacity(reached ? 0 : 1)
            .accessibilityHidden(reached)
    }

    private var buttons: some View {
        Group {
            Button("Accept") { model.acceptScroll() }
                .disabled(!reached)
                .accessibilityHint(reached ? "" : PolicyText.scrollHint)
            Button("Decline", role: .cancel) { model.decline(policy) }
        }
    }

    @ViewBuilder private var content: some View {
        #if os(watchOS)
        // One scroll: the crown reaches the buttons after the end marker.
        VStack(alignment: .leading, spacing: 8) {
            titleView
            AtlasPolicyScroller(policy: policy, style: style, onReachedEnd: end) {
                VStack(spacing: 8) {
                    Button("Accept") { model.acceptScroll() }.disabled(!reached)
                    Button("Decline") { model.decline(policy) }
                }
            }
        }
        #elseif os(tvOS)
        VStack(alignment: .leading, spacing: 24) {
            titleView
            AtlasPolicyScroller(policy: policy, style: style, onReachedEnd: end) { EmptyView() }
            hint
            HStack(spacing: 40) {
                buttons
            }
        }
        .padding(60)
        #else
        VStack(alignment: .leading, spacing: 12) {
            titleView
            AtlasPolicyScroller(policy: policy, style: style, onReachedEnd: end) { EmptyView() }
            hint
            HStack {
                Button("Decline", role: .cancel) { model.decline(policy) }
                Spacer()
                Button("Accept") { model.acceptScroll() }
                    .disabled(!reached)
                    .accessibilityHint(reached ? "" : PolicyText.scrollHint)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        #endif
    }
}

/// The in-app viewer for a checkbox or clickwrap policy: the exact version, read in
/// place (never a browser tab). Closing it is allowed.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasPolicyViewer: View {
    @ObservedObject var model: PolicyAcceptanceModel
    let policy: AtlasPolicy
    let style: AtlasStyle?

    var body: some View {
        content
            .onDisappear { model.endReading(policy) }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
            #endif
    }

    @ViewBuilder private var content: some View {
        #if os(watchOS)
        VStack(alignment: .leading, spacing: 8) {
            Text(policy.title).font(.headline)
            AtlasPolicyScroller(policy: policy, style: style, onReachedEnd: { model.markReachedEnd(policy) }) {
                Button("Done") { model.closeViewer() }
            }
        }
        #else
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(policy.title)
                    .font(style?.headingFont ?? .headline)
                    .foregroundColor(style.map { $0.palette.color(.text) })
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { model.closeViewer() }
            }
            AtlasPolicyScroller(policy: policy, style: style, onReachedEnd: { model.markReachedEnd(policy) }) {
                EmptyView()
            }
        }
        #if os(tvOS)
        .padding(60)
        #else
        .padding()
        #endif
        #endif
    }
}

/// Attaches the viewer and the unskippable sheet to a screen.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasPolicyPresenter: ViewModifier {
    @ObservedObject var model: PolicyAcceptanceModel
    let style: AtlasStyle?

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.viewing) { policy in
                AtlasPolicyViewer(model: model, policy: policy, style: style)
            }
            .background(
                Color.clear.sheet(item: $model.scrollSheet, onDismiss: { model.scrollSheetDismissed() }) { policy in
                    AtlasPolicyScrollSheet(model: model, policy: policy, style: style)
                }
            )
    }
}

// MARK: - checkbox rows and clickwrap

/// The policy consent block of a sign-up (or a held sign-in): a checkbox for the
/// checkbox-mode policies (combined into one sentence by default), the clickwrap
/// sentence for link-mode policies, and a note for scroll-mode documents shown on
/// submit. Names open the in-app viewer. Pair it with ``PolicyAcceptanceModel/beginSubmit(locale:then:)``
/// on your submit button, and disable that button until
/// ``PolicyAcceptanceState/canSubmit``.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct AtlasPolicyConsent: View {
    @ObservedObject private var model: PolicyAcceptanceModel
    private let style: AtlasStyle?

    public init(model: PolicyAcceptanceModel) {
        self.model = model
        self.style = nil
    }

    init(model: PolicyAcceptanceModel, style: AtlasStyle?) {
        self.model = model
        self.style = style
    }

    private var textColor: Color? { style.map { $0.palette.color(.text) } }
    private var font: Font { style?.smallFont ?? .footnote }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            checkboxes
            clickwrap
            scrollNote
            if let message = model.message {
                Text(message)
                    .font(font)
                    .foregroundColor(style.map { $0.palette.color(.danger) } ?? .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(AtlasPolicyPresenter(model: model, style: style))
    }

    // checkbox policies

    @ViewBuilder private var checkboxes: some View {
        let boxes = model.state.checkboxPolicies
        if model.combined && boxes.count > 1 {
            row(
                policies: boxes, prefix: "I agree to the ",
                on: model.state.allCheckboxesTicked,
                toggle: { model.setAllCheckboxes($0) }
            )
        } else {
            ForEach(boxes) { policy in
                row(
                    policies: [policy], prefix: "I agree to the ",
                    on: model.state.isTicked(policy),
                    toggle: { model.setTicked(policy, $0) }
                )
            }
        }
    }

    @ViewBuilder private func row(
        policies: [AtlasPolicy], prefix: String, on: Bool, toggle: @escaping (Bool) -> Void
    ) -> some View {
        let label = PolicyText.agree(policies.map(\.title))
        #if os(tvOS) || os(watchOS)
        VStack(alignment: .leading, spacing: 6) {
            Button { toggle(!on) } label: {
                HStack(alignment: .top, spacing: 10) {
                    checkImage(on)
                    Text(label).font(font).multilineTextAlignment(.leading)
                }
            }
            .accessibilityValue(on ? "Checked" : "Unchecked")
            readButtons(policies)
        }
        #else
        HStack(alignment: .top, spacing: 10) {
            Button { toggle(!on) } label: { checkImage(on) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(on ? "Checked" : "Unchecked")
                .accessibilityAddTraits(.isButton)
            sentence(policies, prefix: prefix, suffix: "")
        }
        #endif
    }

    private func checkImage(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.title3)
            .foregroundColor(on ? (style.map { $0.palette.color(.primary) } ?? .accentColor) : .secondary)
    }

    // clickwrap policies

    @ViewBuilder private var clickwrap: some View {
        let links = model.state.linkPolicies
        if !links.isEmpty {
            #if os(tvOS) || os(watchOS)
            VStack(alignment: .leading, spacing: 6) {
                Text(PolicyText.clickwrap(links.map(\.title))).font(font)
                readButtons(links)
            }
            #else
            sentence(links, prefix: "By continuing you agree to the ", suffix: ".")
            #endif
        }
    }

    @ViewBuilder private var scrollNote: some View {
        let scrolls = model.state.scrollPolicies
        if !scrolls.isEmpty {
            Text("You will be asked to read the \(PolicyText.join(scrolls.map(\.title))) to the end before you continue.")
                .font(font)
                .foregroundColor(style.map { $0.palette.color(.muted) } ?? .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // pieces

    #if os(tvOS) || os(watchOS)
    private func readButtons(_ policies: [AtlasPolicy]) -> some View {
        ForEach(policies) { policy in
            Button("Read \(policy.title)") { model.open(policy) }
                .font(font)
        }
    }
    #else
    /// "I agree to the [A], [B] and [C]" with the names as links to the viewer.
    private func sentence(_ policies: [AtlasPolicy], prefix: String, suffix: String) -> some View {
        var text = AttributedString(prefix)
        for (i, policy) in policies.enumerated() {
            if i > 0 { text += AttributedString(i == policies.count - 1 ? " and " : ", ") }
            var name = AttributedString(policy.title)
            var comps = URLComponents()
            comps.scheme = "atlas-policy"
            comps.host = "open"
            comps.queryItems = [URLQueryItem(name: "id", value: policy.id)]
            if let url = comps.url { name.link = url }
            text += name
        }
        text += AttributedString(suffix)
        return Text(text)
            .font(font)
            .foregroundColor(textColor)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "atlas-policy",
                      let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "id" })?.value,
                      let policy = model.state.policies.first(where: { $0.id == id }) else {
                    return .systemAction
                }
                model.open(policy)
                return .handled
            })
    }
    #endif
}

// MARK: - in-app re-acceptance

/// A banner for a signed-in user who owes a policy (a new version published, a
/// grace window running): it reads `GET /v1/client/me/policies`, and "Review and
/// accept" opens the documents and posts the acceptance. It shows nothing when
/// nothing is owed. Place it above your app's content.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct AtlasPolicyGate: View {
    @ObservedObject private var session: AtlasAuthSession
    @StateObject private var model: PolicyAcceptanceModel
    @State private var owed: [PolicyStanding] = []
    @State private var reviewing = false
    @State private var busy = false
    @State private var failure: String?
    private let onAccepted: () -> Void

    public init(session: AtlasAuthSession, onAccepted: @escaping () -> Void = {}) {
        _session = ObservedObject(wrappedValue: session)
        _model = StateObject(wrappedValue: PolicyAcceptanceModel())
        self.onAccepted = onAccepted
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !owed.isEmpty && session.isSignedIn {
                Text("Updated policies").font(.headline)
                Text("We have updated: \(PolicyText.join(owed.map(\.title))). Please review and accept.")
                    .font(.footnote)
                if let grace = owed.compactMap(\.graceEndsAt).min() {
                    Text("Accept by \(Date(timeIntervalSince1970: Double(grace) / 1000).formatted(date: .abbreviated, time: .omitted)) to keep your access.")
                        .font(.footnote)
                }
                Button("Review and accept") { Task { await review() } }.disabled(busy)
                if let failure { Text(failure).font(.footnote).foregroundColor(.red) }
            }
        }
        .task(id: session.user?.id) { await refresh() }
        .sheet(isPresented: $reviewing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(PolicyText.pendingTitle).font(.headline)
                ScrollView { AtlasPolicyConsent(model: model) }
                Button("Accept and continue") { submit() }
                    .disabled(busy || !model.state.canSubmit)
                Button("Not now") { reviewing = false }
                if let failure { Text(failure).font(.footnote).foregroundColor(.red) }
            }
            .padding()
        }
    }

    private func refresh() async {
        guard session.isSignedIn, let mine = try? await session.client.myPolicies() else {
            owed = []
            return
        }
        owed = mine.needsAcceptance ? mine.pending : []
    }

    private func review() async {
        busy = true
        failure = nil
        defer { busy = false }
        let pending = owed.compactMap { s -> PendingPolicy? in
            guard let version = s.currentVersionId, let hash = s.contentSHA256 else { return nil }
            return PendingPolicy(
                policy: s.policy, policyId: s.policyId, title: s.title, display: s.display, versionId: version,
                version: s.currentVersion ?? "", contentSHA256: hash, reaccept: s.reaccept,
                summaryOfChanges: s.summaryOfChanges
            )
        }
        do {
            model.load(try await session.client.policies(resolving: pending))
            reviewing = true
        } catch {
            failure = (error as? AtlasError)?.message ?? error.localizedDescription
        }
    }

    private func submit() {
        model.beginSubmit { acceptances in
            Task { @MainActor in
                busy = true
                defer { busy = false }
                do {
                    try await session.client.acceptMyPolicies(acceptances)
                    reviewing = false
                    owed = []
                    onAccepted()
                } catch let error as AtlasError where error.isPolicyAcceptanceRequired {
                    failure = error.message
                    await review()
                } catch {
                    failure = (error as? AtlasError)?.message ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - the held sign-in / sign-up step

/// The "accept to continue" step the prebuilt ``SignIn`` and ``SignUp`` show when the
/// server holds an attempt for policy acceptance: the pending policies as checkbox,
/// clickwrap or unskippable-scroll rows, then Accept and Decline.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasPolicyAcceptStep: View {
    @ObservedObject var policy: PolicyAcceptanceModel
    let style: AtlasStyle?
    let busy: Bool
    let onAccept: ([PolicyAcceptance]) -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: style?.gap ?? 12) {
            Text(PolicyText.pendingTitle)
                .font(style?.headingFont ?? .headline)
                .foregroundColor(style.map { $0.palette.color(.text) })
                .accessibilityAddTraits(.isHeader)
            Text(PolicyText.pendingIntro)
                .font(style?.smallFont ?? .footnote)
                .foregroundColor(style.map { $0.palette.color(.muted) } ?? .secondary)
            if !policy.isLoaded {
                ProgressView()
            } else if policy.state.policies.isEmpty {
                Text("The policies could not be loaded.")
                    .font(style?.smallFont ?? .footnote)
                    .foregroundColor(style.map { $0.palette.color(.danger) } ?? .red)
            } else {
                AtlasPolicyConsent(model: policy, style: style)
                acceptButton
            }
            declineButton
        }
    }

    @ViewBuilder private var acceptButton: some View {
        let disabled = busy || !policy.state.canSubmit
        if let style {
            Button("Accept and continue") { policy.beginSubmit(then: onAccept) }
                .buttonStyle(AtlasPrimaryButtonStyle(style: style))
                .disabled(disabled)
        } else {
            Button("Accept and continue") { policy.beginSubmit(then: onAccept) }
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
        }
    }

    @ViewBuilder private var declineButton: some View {
        if let style {
            Button("Decline") { onDecline() }
                .buttonStyle(AtlasSecondaryButtonStyle(style: style))
                .disabled(busy)
        } else {
            #if os(tvOS) || os(watchOS)
            Button("Decline") { onDecline() }.buttonStyle(.bordered).disabled(busy)
            #else
            Button("Decline") { onDecline() }.disabled(busy)
            #endif
        }
    }
}
#endif
