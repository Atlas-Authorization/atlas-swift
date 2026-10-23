import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What a sign-out hands back for signing out of the upstream identity provider
/// too: the upstream OIDC provider's end-session URL (RP-initiated logout) and
/// the SAML Single Logout start URL. Only `https` URLs are kept.
public struct AtlasSignOutResult: Sendable, Equatable {
    /// The upstream OIDC provider's end-session URL.
    public let upstreamLogoutURL: URL?
    /// The SAML Single Logout start URL for the session's SAML connection.
    public let samlLogoutURL: URL?

    public init(upstreamLogoutURL: URL? = nil, samlLogoutURL: URL? = nil) {
        self.upstreamLogoutURL = upstreamLogoutURL
        self.samlLogoutURL = samlLogoutURL
    }

    /// The URL to open: the SAML one, else the upstream OIDC one.
    public var logoutURL: URL? { samlLogoutURL ?? upstreamLogoutURL }

    /// Read the logout URLs from a session-revoke response body.
    init(responseBody data: Data) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let root = object["response"] as? [String: Any] ?? object
        func https(_ key: String) -> URL? {
            guard let raw = (root[key] ?? object[key]) as? String, raw.hasPrefix("https://") else { return nil }
            return URL(string: raw)
        }
        self.init(upstreamLogoutURL: https("upstream_logout_url"), samlLogoutURL: https("saml_logout_url"))
    }
}

extension AtlasClient {
    /// Open `url` in the system browser (iOS, visionOS, macOS). A no-op on tvOS
    /// and watchOS, which have no browser.
    @MainActor
    public static func openInSystemBrowser(_ url: URL) async {
        #if os(iOS) || os(visionOS)
        _ = await UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// The default ``logoutURLOpener``: the system browser where there is one.
    static var defaultLogoutURLOpener: (@Sendable (URL) async -> Void)? {
        #if os(iOS) || os(visionOS) || os(macOS)
        return { url in await AtlasClient.openInSystemBrowser(url) }
        #else
        return nil
        #endif
    }
}
