// "Sign in on another device" (RFC 8628) as SwiftUI: the lead sign-in flow on
// Apple TV and Apple Watch, and available on every other Apple platform too.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - QR code

/// A QR code drawn as crisp vector modules, black on white with the standard
/// four-module quiet zone (whatever the colour scheme, so every camera reads it).
/// Encodes with Core Image where available, the SDK's own encoder on watchOS
/// (see ``AtlasQRCode``).
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct AtlasQRCodeView: View {
    private let code: AtlasQRCode?

    /// - Parameter text: the content to encode (a URL, an `otpauth://` URI, …).
    public init(text: String) {
        self.code = AtlasQRCode(text)
    }

    /// Draw an already-encoded symbol.
    public init(code: AtlasQRCode) {
        self.code = code
    }

    public var body: some View {
        if let code {
            Canvas(rendersAsynchronously: false) { context, size in
                let quiet = 4
                let side = min(size.width, size.height)
                let cell = side / CGFloat(code.size + quiet * 2)
                let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
                context.fill(Path(CGRect(origin: origin, size: CGSize(width: side, height: side))), with: .color(.white))
                var dark = Path()
                for y in 0..<code.size {
                    for x in 0..<code.size where code[x, y] {
                        dark.addRect(CGRect(
                            x: origin.x + CGFloat(x + quiet) * cell,
                            y: origin.y + CGFloat(y + quiet) * cell,
                            // A hair of overlap so adjacent modules never show seams.
                            width: cell + 0.5, height: cell + 0.5
                        ))
                    }
                }
                context.fill(dark, with: .color(.black))
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement()
            .accessibilityLabel("QR code")
            .accessibilityAddTraits(.isImage)
        }
    }
}

// MARK: - model

/// Drives a device sign-in for the UI: start, show the code, wait, renew the
/// code when it expires (a few times, so a TV left on the screen keeps a live
/// code), and report the outcome. `@MainActor` so the published state is
/// main-thread.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class DeviceSignInModel: ObservableObject {
    enum Phase: Equatable {
        /// Asking the server for a code.
        case requesting
        /// Showing the code and waiting for approval.
        case waiting(AtlasDeviceAuthorization)
        /// The code expired and the automatic renewals are used up.
        case expired
        /// The person declined on their other device.
        case denied
        /// Anything else, with the message to show.
        case failed(String)
        /// Signed in.
        case completed
    }

    /// How many times an expired code is replaced without asking.
    static let automaticRenewals = 3

    @Published private(set) var phase: Phase = .requesting
    /// The QR code of the current code's verification link.
    @Published private(set) var qrCode: AtlasQRCode?
    @Published private(set) var completed = false
    /// Bumped to (re)start; the view's `.task(id:)` follows it, cancelling any
    /// wait in progress.
    @Published private(set) var attempt = 0

    let session: AtlasAuthSession
    let clientId: String?
    let scopes: [String]
    let deviceName: String?
    private var renewals = 0

    init(session: AtlasAuthSession, clientId: String? = nil, scopes: [String] = [], deviceName: String? = nil) {
        self.session = session
        self.clientId = clientId
        self.scopes = scopes
        self.deviceName = deviceName
    }

    /// Whether this app is set up for the device flow (an OAuth client id).
    var isAvailable: Bool {
        !((clientId ?? session.client.oauthClientId) ?? "").isEmpty
    }

    /// Start over with a fresh code (the "Get a new code" / "Try again" action).
    func restart() {
        renewals = 0
        attempt += 1
    }

    /// Run the flow until it signs in, fails, or the calling task is cancelled.
    func run() async {
        guard isAvailable, !completed else { return }
        while !Task.isCancelled {
            phase = .requesting
            qrCode = nil
            do {
                let authorization = try await session.client.startDeviceSignIn(clientId: clientId, scopes: scopes)
                qrCode = AtlasQRCode(authorization.qrCodeURL.absoluteString)
                phase = .waiting(authorization)
                try await session.client.waitForDeviceSignIn(authorization, deviceName: deviceName)
                await session.reload()
                phase = .completed
                completed = true
                return
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                let atlasError = error as? AtlasError
                if atlasError?.isDeviceCodeExpired == true {
                    if renewals < Self.automaticRenewals {
                        renewals += 1
                        continue
                    }
                    phase = .expired
                } else if atlasError?.isDeviceSignInDenied == true {
                    phase = .denied
                } else {
                    phase = .failed(atlasError?.message ?? error.localizedDescription)
                }
                return
            }
        }
    }
}

// MARK: - public view

/// "Sign in on another device": shows a short code and a QR code, waits while
/// the person approves on their phone or computer, then establishes the session
/// (``AtlasClient/startDeviceSignIn(clientId:scopes:)`` +
/// ``AtlasClient/waitForDeviceSignIn(_:deviceName:)``).
///
/// The layout is native per platform: on tvOS the steps and the code sit beside
/// a large QR code, sized for the sofa; on watchOS the QR code fills the width
/// with the code beneath; elsewhere a centred column. A countdown shows the
/// code's remaining life and expired codes are renewed automatically.
///
/// ``SignIn`` leads with this on tvOS and watchOS; use it directly for a custom
/// sign-in screen.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
public struct AtlasDeviceSignInView: View {
    @StateObject private var model: DeviceSignInModel
    @StateObject private var design: DeviceSignInDesign
    @Environment(\.colorScheme) private var systemScheme
    private let appearance: AtlasAppearance?
    private let onComplete: () -> Void

    /// - Parameters:
    ///   - session: the session to sign in and refresh.
    ///   - clientId: the first-party OAuth client; defaults to the client's
    ///     ``AtlasClient/oauthClientId``.
    ///   - scopes: scopes to request; empty asks for the client's configured set.
    ///   - deviceName: the name shown in the person's device list; defaults to
    ///     ``AtlasClient/platformDeviceName``.
    ///   - appearance: code-level design overrides (win over the dashboard design).
    ///   - onComplete: called after the session is established.
    public init(
        session: AtlasAuthSession,
        clientId: String? = nil,
        scopes: [String] = [],
        deviceName: String? = nil,
        appearance: AtlasAppearance? = nil,
        onComplete: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: DeviceSignInModel(
            session: session, clientId: clientId, scopes: scopes, deviceName: deviceName
        ))
        _design = StateObject(wrappedValue: DeviceSignInDesign(client: session.client))
        self.appearance = appearance
        self.onComplete = onComplete
    }

    private var style: AtlasStyle? {
        AtlasDesign.resolve(dashboard: design.info?.design, appearance: appearance)
            .map { AtlasStyle(design: $0, systemIsDark: systemScheme == .dark) }
    }

    public var body: some View {
        AtlasDeviceCodePanel(model: model, style: style)
            .task(id: model.attempt) { await model.run() }
            .task { await design.load() }
            .onChange(of: model.completed) { done in if done { onComplete() } }
    }
}

/// The dashboard design for the standalone view, fetched once.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class DeviceSignInDesign: ObservableObject {
    @Published private(set) var info: AtlasAppearanceInfo?
    private let client: AtlasClient
    private var requested = false

    init(client: AtlasClient) { self.client = client }

    func load() async {
        guard !requested else { return }
        requested = true
        info = try? await client.appearance()
    }
}

// MARK: - the panel

/// The device-code panel shared by ``AtlasDeviceSignInView`` and ``SignIn``.
@available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
struct AtlasDeviceCodePanel: View {
    @ObservedObject var model: DeviceSignInModel
    let style: AtlasStyle?

    var body: some View {
        switch model.phase {
        case .requesting:
            ProgressView()
                .tint(style.map { $0.palette.color(.primary) })
                .frame(maxWidth: .infinity, minHeight: Metrics.qrSide / 2)
        case let .waiting(authorization):
            waiting(authorization)
        case .expired:
            outcome("This code expired.", systemImage: "clock.badge.exclamationmark", action: "Get a new code")
        case .denied:
            outcome("Sign-in was declined on your other device.", systemImage: "hand.raised", action: "Try again")
        case let .failed(message):
            outcome(message, systemImage: "exclamationmark.triangle", action: "Try again")
        case .completed:
            Label("You're signed in.", systemImage: "checkmark.circle.fill")
                .font(textFont(.body))
                .foregroundColor(style?.palette.color(.success) ?? .green)
        }
    }

    // MARK: waiting

    @ViewBuilder private func waiting(_ authorization: AtlasDeviceAuthorization) -> some View {
        #if os(tvOS)
        HStack(alignment: .center, spacing: 60) {
            VStack(alignment: .leading, spacing: 28) {
                Text("Sign in with your phone or computer")
                    .font(textFont(.title3)).bold()
                step(1, "Go to", value: authorization.displayVerificationURI)
                step(2, "Enter this code", code: authorization.userCode)
                countdown(authorization)
            }
            qr(caption: "Or scan with your phone's camera")
        }
        #elseif os(watchOS)
        VStack(spacing: 6) {
            qr(caption: nil)
            Text("Scan, or visit \(authorization.displayVerificationURI) and enter")
                .font(textFont(.footnote))
                .foregroundColor(mutedColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            codeText(authorization.userCode)
            countdown(authorization)
        }
        .frame(maxWidth: .infinity)
        #else
        VStack(spacing: 16) {
            qr(caption: "Scan with your phone's camera")
            Text("or go to \(authorization.displayVerificationURI) and enter")
                .font(textFont(.subheadline))
                .foregroundColor(mutedColor)
                .multilineTextAlignment(.center)
            codeText(authorization.userCode)
            countdown(authorization)
        }
        .frame(maxWidth: .infinity)
        #endif
    }

    @ViewBuilder private func qr(caption: String?) -> some View {
        VStack(spacing: 12) {
            if let code = model.qrCode {
                AtlasQRCodeView(code: code)
                    .frame(maxWidth: Metrics.qrSide, maxHeight: Metrics.qrSide)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.qrCorner, style: .continuous))
            }
            if let caption {
                Text(caption).font(textFont(.caption)).foregroundColor(mutedColor)
            }
        }
    }

    #if os(tvOS)
    @ViewBuilder private func step(_ number: Int, _ title: String, value: String? = nil, code: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text("\(number)")
                .font(textFont(.headline))
                .frame(width: 48, height: 48)
                .background(Circle().fill(primaryColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(textFont(.body)).foregroundColor(mutedColor)
                if let value { Text(value).font(textFont(.title2)).bold() }
                if let code { codeText(code) }
            }
        }
    }
    #endif

    /// The user code, large and monospaced, spoken character by character.
    private func codeText(_ code: String) -> some View {
        Text(code)
            .font(.system(size: Metrics.codeSize, weight: .bold, design: .monospaced))
            .foregroundColor(style?.palette.color(.text))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
    }

    private func countdown(_ authorization: AtlasDeviceAuthorization) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let seconds = authorization.secondsRemaining(at: context.date)
            Text("Code expires in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .font(textFont(.caption))
                .foregroundColor(mutedColor)
                .monospacedDigit()
        }
    }

    // MARK: outcomes

    @ViewBuilder private func outcome(_ message: String, systemImage: String, action: String) -> some View {
        VStack(spacing: 16) {
            Label(message, systemImage: systemImage)
                .font(textFont(.body))
                .multilineTextAlignment(.center)
            if let style {
                Button(action) { model.restart() }
                    .buttonStyle(AtlasPrimaryButtonStyle(style: style))
            } else {
                Button(action) { model.restart() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: styling

    private var mutedColor: Color { style?.palette.color(.muted) ?? .secondary }
    private var primaryColor: Color { style?.palette.color(.primary) ?? .accentColor }

    /// The design's font at the platform scale, or the system text style.
    private func textFont(_ textStyle: Font.TextStyle) -> Font {
        guard let style else { return .system(textStyle) }
        switch textStyle {
        case .largeTitle, .title, .title2, .title3, .headline: return style.headingFont
        case .caption, .caption2, .footnote, .subheadline: return style.smallFont
        default: return style.bodyFont
        }
    }

    enum Metrics {
        static var qrSide: Double {
            #if os(tvOS)
            return 440
            #elseif os(watchOS)
            return 150
            #else
            return 220
            #endif
        }

        static var qrCorner: Double {
            #if os(tvOS)
            return 24
            #elseif os(watchOS)
            return 8
            #else
            return 12
            #endif
        }

        static var codeSize: Double {
            #if os(tvOS)
            return 76
            #elseif os(watchOS)
            return 24
            #else
            return 40
            #endif
        }
    }
}
#endif
