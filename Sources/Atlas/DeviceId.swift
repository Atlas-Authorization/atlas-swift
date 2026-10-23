import Foundation

/// The stable device id the SDK sends on every start that can create an account
/// (email sign-up, social / SSO / id_token sign-ins), so the instance's
/// accounts-per-device abuse limit can count devices rather than networks —
/// the native peer of the JS SDK's `device_id`. Password and passwordless
/// sign-ins never create an account and do not send it.
///
/// The id is random (`d_` + a UUID), carries no hardware identifier, and is kept
/// in `UserDefaults` so it survives app launches.
public enum DeviceId {
    /// The routes that carry `device_id` (the JS SDK's `DEVICE_ID_ROUTES`).
    public static let routes: Set<String> = [
        "/v1/client/sign_ups",
        "/v1/client/sign_ins/oauth",
        "/v1/client/sign_ins/sso",
        "/v1/client/sign_ins/saml",
        "/v1/client/sign_ins/discourse",
        "/v1/client/sign_ins/id_token",
        "/v1/client/sign_ins/external_jwt",
        "/v1/client/sign_ins/ldap",
        "/v1/oauth/telegram",
        "/v1/oauth/siwe/verify",
        "/v1/oauth/siws/verify",
        "/v1/oauth/siwf/verify",
    ]

    static let defaultsKey = "__atlas_did"

    /// This install's device id, created on first use.
    public static func current(_ defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty { return existing }
        let fresh = "d_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// `json` with `device_id` added when `path` is a device-id route and the body
    /// does not already carry one.
    static func stamp(_ json: [String: Any]?, path: String, method: String, id: () -> String?) -> [String: Any]? {
        guard method == "POST", var json else { return json }
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard routes.contains(bare), json["device_id"] == nil, let value = id() else { return json }
        json["device_id"] = value
        return json
    }
}
