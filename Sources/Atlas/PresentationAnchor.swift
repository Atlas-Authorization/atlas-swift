#if canImport(AuthenticationServices) && !os(watchOS)
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where the system's authentication sheets (passkeys, Sign in with Apple, the
/// hosted-sign-in web session) anchor. One implementation for every Apple
/// platform that presents them, so the platforms cannot drift apart.
///
/// - iOS, iPadOS, tvOS: the key window of the foreground-active `UIWindowScene`.
/// - visionOS: the same scene lookup — a visionOS app's windows live in
///   `UIWindowScene`s too — and, when the app has a scene but no window yet (an
///   immersive-space-only launch, or a volume with no 2D content), a window
///   attached to that scene, so the sheet still appears in front of the person
///   rather than in a detached default window.
/// - macOS: the key window, else the first window.
enum AtlasPresentationAnchor {
    static func current() -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first {
            return window
        }
        #if os(visionOS)
        if let scene { return UIWindow(windowScene: scene) }
        #endif
        return ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
