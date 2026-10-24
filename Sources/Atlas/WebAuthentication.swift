import Foundation
#if canImport(AuthenticationServices) && !os(tvOS)
import AuthenticationServices

/// Hosted sign-in through `ASWebAuthenticationSession`: the system browser sheet
/// that runs an OAuth / SSO / SAML sign-in and hands the redirect back to the app.
/// Native on iOS, iPadOS, macOS, visionOS and watchOS; tvOS has no web browser
/// (use device sign-in there).
///
/// On visionOS the sheet is anchored to the app's window scene
/// (see `AtlasPresentationAnchor`); on watchOS the system presents it itself.
@available(iOS 13.0, macOS 10.15, watchOS 6.2, *)
public final class AtlasWebAuthentication: NSObject {
    private var session: ASWebAuthenticationSession?

    public override init() { super.init() }

    /// Open `url` and wait for the redirect to `callbackURLScheme`.
    ///
    /// - Parameters:
    ///   - url: the authorize URL (e.g. from ``AtlasClient/oauthAuthorizeURL(provider:redirectURI:)``).
    ///   - callbackURLScheme: the custom scheme the redirect comes back on.
    ///   - prefersEphemeralSession: do not share cookies or history with the
    ///     system browser (no single sign-on, but nothing left behind).
    /// - Returns: the callback URL.
    /// - Throws: `ASWebAuthenticationSessionError` (`.canceledLogin` when the
    ///   person dismisses the sheet), or ``AtlasError`` if the session cannot start.
    @MainActor
    public func authenticate(
        url: URL,
        callbackURLScheme: String,
        prefersEphemeralSession: Bool = false
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? AtlasError.transport("The web sign-in ended without a redirect."))
                }
            }
            session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
            #if !os(watchOS)
            session.presentationContextProvider = self
            #endif
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: AtlasError.transport("The web sign-in session could not start."))
            }
        }
    }
}

#if !os(watchOS)
@available(iOS 13.0, macOS 10.15, *)
extension AtlasWebAuthentication: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        AtlasPresentationAnchor.current()
    }
}
#endif

@available(iOS 13.0, macOS 10.15, watchOS 6.2, *)
extension AtlasClient {
    /// Sign in through a social / SSO provider in the system web sheet: builds the
    /// authorize URL, runs `ASWebAuthenticationSession`, and completes the redirect
    /// (``completeRedirect(_:)``) — so the app writes one call, on every platform
    /// that has a web sheet (iOS, macOS, visionOS, watchOS).
    ///
    /// - Parameters:
    ///   - provider: the provider key (`google`, `github`, …).
    ///   - callbackURLScheme: your app's custom URL scheme.
    ///   - redirectURI: the redirect URL registered for the app; defaults to
    ///     `"<scheme>://atlas/callback"`. It must be allowed on the instance.
    ///   - prefersEphemeralSession: see ``AtlasWebAuthentication/authenticate(url:callbackURLScheme:prefersEphemeralSession:)``.
    /// - Returns: ``AtlasRedirectOutcome/signedIn(_:)`` once the session is
    ///   established, or the flow to continue when the sign-in still owes a policy
    ///   or a second factor.
    @MainActor
    public func signInWithBrowser(
        provider: String,
        callbackURLScheme: String,
        redirectURI: String? = nil,
        prefersEphemeralSession: Bool = false
    ) async throws -> AtlasRedirectOutcome {
        let redirect = redirectURI ?? "\(callbackURLScheme)://atlas/callback"
        let authorizeURL = try await oauthAuthorizeURL(provider: provider, redirectURI: redirect)
        let callback = try await AtlasWebAuthentication().authenticate(
            url: authorizeURL,
            callbackURLScheme: callbackURLScheme,
            prefersEphemeralSession: prefersEphemeralSession
        )
        guard let outcome = try await completeRedirect(callback) else {
            throw AtlasError.decoding("The redirect was not an Atlas sign-in callback.")
        }
        return outcome
    }
}
#endif
