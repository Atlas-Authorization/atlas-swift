import Foundation
import Security

/// The production `TokenStore`: the session lives in the Keychain, encrypted at
/// rest by the OS and outside the app's own sandboxed files.
///
/// One item per `service` + `account`, holding the JSON-encoded ``AtlasSession``.
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is deliberate: the token
/// is readable in the background (a refresh that fires while the phone is
/// locked) but never leaves the device in a backup, which a session token has no
/// business doing.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?

    /// - Parameters:
    ///   - service: keychain service key; default namespaces by the SDK.
    ///   - account: the account key, usually the publishable key so two
    ///     instances in one app do not collide.
    ///   - accessGroup: a keychain sharing group, for an app + its extensions.
    public init(service: String = "com.atlas.sdk.session",
                account: String,
                accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func save(_ session: AtlasSession) throws {
        let data = try JSONEncoder().encode(session)

        // Update-then-add: SecItemUpdate fails if the item is absent, so try it
        // first and fall back to add. Deleting-then-adding would briefly leave no
        // token, losing a concurrent read.
        var attributes: [String: Any] = baseQuery()
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw AtlasError.transport("Keychain update failed (OSStatus \(updateStatus)).")
        }

        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AtlasError.transport("Keychain add failed (OSStatus \(addStatus)).")
        }
    }

    public func load() throws -> AtlasSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AtlasError.transport("Keychain read failed (OSStatus \(status)).")
        }
        return try JSONDecoder().decode(AtlasSession.self, from: data)
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AtlasError.transport("Keychain delete failed (OSStatus \(status)).")
        }
    }
}
