import Foundation

/// Device-bound biometric sign-in (the Swift peer of the JS `registerDeviceKey` /
/// `signInWithDeviceKey`). An ES256 (P-256) key lives in the Secure Enclave and is
/// unlocked by Face ID / Touch ID; Atlas stores only the public half. Signing in
/// means signing a single-use server challenge.
///
///   register: POST /v1/client/me/device_keys/challenge → sign → /device_keys
///   sign in : POST /v1/client/sign_ins/device_key/challenge → sign → /finish

/// A P-256 public key as a JWK (`x` and `y` base64url).
public struct AtlasDeviceKeyJWK: Sendable, Equatable {
    public let x: String
    public let y: String
    var json: [String: String] { ["kty": "EC", "crv": "P-256", "x": x, "y": y] }
}

/// The keystore contract: create a key and sign with it (behind the biometric prompt).
public protocol AtlasDeviceKeySigner: Sendable {
    /// Creates the keypair and returns its public JWK. `biometric` asks for a key that needs Face ID / Touch ID to use.
    func createKey(biometric: Bool) async throws -> AtlasDeviceKeyJWK
    /// Signs the UTF-8 message with ES256 and returns base64url IEEE-P1363 (`r || s`).
    func sign(message: String) async throws -> String
}

/// The `device_key` resource the server returns.
public struct AtlasDeviceKey: Decodable, Sendable, Equatable {
    public let id: String
    public let label: String?
    public let platform: String?
    public let biometricBound: Bool
    public let lastUsedAt: Int64?
    public let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, label, platform
        case biometricBound = "biometric_bound"
        case lastUsedAt = "last_used_at"
        case createdAt = "created_at"
    }
}

enum AtlasDeviceKeyMessage {
    /// The exact string the device signs; mirrors the server.
    static func make(purpose: String, instanceId: String, keyId: String, nonce: String) -> String {
        "atlas-device-key:v1:\(purpose):\(instanceId):\(keyId):\(nonce)"
    }

    /// The uncompressed X9.63 point (`04 || X || Y`, 65 bytes) as a JWK.
    static func jwk(fromX963 point: Data) -> AtlasDeviceKeyJWK? {
        guard point.count == 65, point.first == 0x04 else { return nil }
        return AtlasDeviceKeyJWK(
            x: point.subdata(in: 1..<33).base64URLEncodedString(),
            y: point.subdata(in: 33..<65).base64URLEncodedString()
        )
    }

    /// Converts an ASN.1 DER ECDSA signature (what Security.framework emits) to
    /// the fixed 64-byte `r || s` the server verifies. Nil when malformed.
    static func p1363(fromDER der: Data) -> Data? {
        let b = [UInt8](der)
        var i = 0
        func readLength() -> Int? {
            guard i < b.count else { return nil }
            let first = Int(b[i]); i += 1
            if first < 0x80 { return first }
            let n = first & 0x7f
            guard n > 0, n <= 2, i + n <= b.count else { return nil }
            var len = 0
            for _ in 0..<n { len = (len << 8) | Int(b[i]); i += 1 }
            return len
        }
        func readInt() -> [UInt8]? {
            guard i < b.count, b[i] == 0x02 else { return nil }
            i += 1
            guard let len = readLength(), len > 0, i + len <= b.count else { return nil }
            var v = Array(b[i..<(i + len)]); i += len
            while v.count > 1, v.first == 0 { v.removeFirst() }
            guard v.count <= 32 else { return nil }
            return [UInt8](repeating: 0, count: 32 - v.count) + v
        }
        guard i < b.count, b[i] == 0x30 else { return nil }
        i += 1
        guard readLength() != nil, let r = readInt(), let s = readInt() else { return nil }
        return Data(r + s)
    }
}

extension AtlasClient {
    /// Registers this device's key for the signed-in user (needs a recent
    /// re-authentication and `accountUx.deviceKeys.enabled`). Keep the returned
    /// ``AtlasDeviceKey/id`` (for example in the Keychain) and pass it to
    /// ``signInWithDeviceKey(signer:instanceId:deviceKeyId:captchaToken:)``.
    ///
    /// - Parameter instanceId: your instance id (`ins_…`), shown in the dashboard.
    @discardableResult
    public func registerDeviceKey(
        signer: AtlasDeviceKeySigner,
        instanceId: String,
        label: String? = nil,
        biometric: Bool = true
    ) async throws -> AtlasDeviceKey {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        let bearer = stored.token
        let (challengeData, challengeResponse) = try await send(
            "POST", "/v1/client/me/device_keys/challenge", body: [:], refreshCookie: nil, authorization: bearer
        )
        try throwIfError(status: challengeResponse.statusCode, data: challengeData)
        guard let nonce = (try? JSONSerialization.jsonObject(with: challengeData) as? [String: Any])?["nonce"] as? String else {
            throw AtlasError.decoding("The device-key challenge had no nonce.")
        }
        let jwk = try await signer.createKey(biometric: biometric)
        // Proof of possession: the register message names the key by its x coordinate.
        let signature = try await signer.sign(
            message: AtlasDeviceKeyMessage.make(purpose: "register", instanceId: instanceId, keyId: jwk.x, nonce: nonce)
        )
        var body: [String: Any] = [
            "nonce": nonce,
            "public_key": jwk.json,
            "signature": signature,
            "biometric_bound": biometric,
            "platform": "ios",
        ]
        if let label, !label.isEmpty { body["label"] = label }
        let (data, response) = try await sendJSON(
            "POST", "/v1/client/me/device_keys", json: body, refreshCookie: nil, authorization: bearer
        )
        try throwIfError(status: response.statusCode, data: data)
        return try decode(AtlasDeviceKey.self, from: data)
    }

    /// Removes one of the signed-in user's device keys (needs a recent re-authentication).
    public func removeDeviceKey(id: String) async throws {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        let (data, response) = try await send(
            "DELETE", "/v1/client/me/device_keys/\(id)", body: nil, refreshCookie: nil, authorization: stored.token
        )
        try throwIfError(status: response.statusCode, data: data)
    }

    /// Signs in with the registered device key: fetches a challenge, signs it
    /// (Face ID / Touch ID prompt), and persists the session like any sign-in.
    ///
    /// - Throws: ``AtlasPolicyAcceptanceNeeded`` when a policy must be accepted
    ///   first; ``AtlasError`` otherwise (a 400 whatever the cause: unknown or
    ///   revoked key, bad signature). If the instance still requires MFA the
    ///   server answers `needs_second_factor`, surfaced as ``AtlasError``.
    @discardableResult
    public func signInWithDeviceKey(
        signer: AtlasDeviceKeySigner,
        instanceId: String,
        deviceKeyId: String
    ) async throws -> AtlasUser {
        let (challengeData, challengeResponse) = try await send(
            "POST", "/v1/client/sign_ins/device_key/challenge",
            body: ["device_key_id": deviceKeyId], refreshCookie: nil
        )
        try throwIfError(status: challengeResponse.statusCode, data: challengeData)
        guard let nonce = (try? JSONSerialization.jsonObject(with: challengeData) as? [String: Any])?["nonce"] as? String else {
            throw AtlasError.decoding("The device-key challenge had no nonce.")
        }
        let signature = try await signer.sign(
            message: AtlasDeviceKeyMessage.make(purpose: "sign_in", instanceId: instanceId, keyId: deviceKeyId, nonce: nonce)
        )
        let (data, response) = try await send(
            "POST", "/v1/client/sign_ins/device_key/finish",
            body: ["device_key_id": deviceKeyId, "nonce": nonce, "signature": signature], refreshCookie: nil
        )
        try throwIfError(status: response.statusCode, data: data)
        if let held = try? decode(SignInAttempt.self, from: data) {
            if held.status == SignInStatus.needsPolicyAcceptance.rawValue {
                throw AtlasPolicyAcceptanceNeeded(flow: SignInFlow(client: self, attempt: held))
            }
            if held.status == "needs_second_factor" {
                throw AtlasError.transport("This account still needs a second factor after the device key.")
            }
        }
        let session = try decode(PasskeySignInResponse.self, from: data)
        try tokenStore.save(AtlasSession(
            sessionId: session.createdSessionId ?? "",
            token: session.jwt,
            refreshToken: extractCookie(Cookie.refresh, from: response)
        ))
        return try await currentUser()
    }
}

#if canImport(Security) && canImport(LocalAuthentication) && !os(tvOS) && !os(watchOS)
import Security
import LocalAuthentication

/// A Secure Enclave signer: the private key never leaves the chip and a
/// biometric key needs Face ID / Touch ID (this enrolment's set) for every
/// signature. On a Simulator, which has no Secure Enclave, it falls back to a
/// Keychain key so the flow can be developed.
public final class AtlasSecureEnclaveSigner: AtlasDeviceKeySigner, @unchecked Sendable {
    private let tag: Data
    private let prompt: String

    /// - Parameters:
    ///   - tag: a stable identifier for this app's key (reverse-DNS).
    ///   - prompt: the reason shown in the biometric sheet.
    public init(tag: String = "net.atlasauth.device-key", prompt: String = "Sign in") {
        self.tag = Data(tag.utf8)
        self.prompt = prompt
    }

    public func createKey(biometric: Bool) async throws -> AtlasDeviceKeyJWK {
        try? deleteKey()
        var flags: SecAccessControlCreateFlags = biometric ? [.biometryCurrentSet] : []
        #if !targetEnvironment(simulator)
        flags.insert(.privateKeyUsage)
        #endif
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, flags, &cfError
        ) else {
            throw AtlasError.transport("Could not create the key access control: \(cfError?.takeRetainedValue().localizedDescription ?? "unknown").")
        }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        #if !targetEnvironment(simulator)
        attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &cfError) else {
            throw AtlasError.transport("Could not create the device key: \(cfError?.takeRetainedValue().localizedDescription ?? "unknown").")
        }
        guard
            let publicKey = SecKeyCopyPublicKey(privateKey),
            let point = SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data?,
            let jwk = AtlasDeviceKeyMessage.jwk(fromX963: point)
        else {
            throw AtlasError.transport("Could not read the device public key.")
        }
        return jwk
    }

    public func sign(message: String) async throws -> String {
        let context = LAContext()
        context.localizedReason = prompt
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item else {
            throw AtlasError.transport("No device key is registered on this device.")
        }
        let privateKey = item as! SecKey // SecItemCopyMatching with kSecReturnRef on a key class returns a SecKey
        var cfError: Unmanaged<CFError>?
        guard let der = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, Data(message.utf8) as CFData, &cfError
        ) as Data?, let raw = AtlasDeviceKeyMessage.p1363(fromDER: der) else {
            throw AtlasError.transport("The device key could not sign: \(cfError?.takeRetainedValue().localizedDescription ?? "cancelled").")
        }
        return raw.base64URLEncodedString()
    }

    /// Deletes this device's key (call after the user removes the device or signs out for good).
    public func deleteKey() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
        ] as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw AtlasError.transport("Could not delete the device key (status \(status)).")
        }
    }
}
#endif
