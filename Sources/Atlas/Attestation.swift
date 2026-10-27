import Foundation

/// The OS proof for one single-use nonce (see ``AtlasClient/attestationProvider``).
public enum AtlasAttestationProof: Sendable {
    /// Apple App Attest: the base64 assertion for the nonce plus the receipt
    /// ``AtlasClient/registerAppAttestKey(attest:)`` returned.
    case appAttest(assertion: String, receipt: String)
    /// A Google Play Integrity token (for Swift targets that talk to an Android-attested backend; rarely used).
    case integrityToken(String)
    /// The base64 `DCDevice` token, for devices without App Attest.
    case deviceCheck(token: String)
}

/// App and device attestation for native clients.
///
/// When an instance turns on `attackProtection.appAttestation`, sign-up, sign-in
/// and SMS-send requests must carry an `Atlas-Attestation` proof. Set
/// ``AtlasClient/attestationProvider`` and the client fetches a single-use nonce
/// and attaches the proof to those calls itself.
enum AtlasAttestation {
    static func isGuarded(path: String, method: String) -> Bool {
        guard method == "POST" else { return false }
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if bare == "/v1/client/sign_ups" || bare == "/v1/client/sign_ins" || bare == "/v1/client/me/phone_numbers" { return true }
        return bare.hasPrefix("/v1/client/me/phone_numbers/") && bare.hasSuffix("/prepare_verification")
    }

    /// base64url JSON, the format the server reads from the `Atlas-Attestation` header.
    static func header(nonce: String, proof: AtlasAttestationProof) -> String {
        var body: [String: String] = ["n": nonce]
        switch proof {
        case let .appAttest(assertion, receipt):
            body["p"] = "ios"; body["a"] = assertion; body["r"] = receipt
        case let .integrityToken(token):
            body["p"] = "android"; body["t"] = token
        case let .deviceCheck(token):
            body["p"] = "ios_dc"; body["t"] = token
        }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct AppAttestRegistration: Sendable {
    public let receipt: String
    public let expiresAt: Int64
}

extension AtlasClient {
    /// Registers an App Attest key once per install. `attest` receives the server
    /// challenge, runs `DCAppAttestService.attestKey` with SHA-256 of it as the
    /// client-data hash, and returns the base64 key id and attestation object.
    /// Keep the returned receipt and hand it to ``attestationProvider`` with each assertion.
    public func registerAppAttestKey(
        attest: (String) async throws -> (keyId: String, attestation: String)
    ) async throws -> AppAttestRegistration {
        let (challengeData, _) = try await sendJSON("POST", "/v1/client/attestation/challenge", json: [:], refreshCookie: nil)
        guard let nonce = (try? JSONSerialization.jsonObject(with: challengeData) as? [String: Any])?["nonce"] as? String else {
            throw AtlasError.transport("The server did not return an attestation challenge.")
        }
        let proof = try await attest(nonce)
        let (data, _) = try await sendJSON(
            "POST", "/v1/client/attestation/app_attest/register",
            json: ["nonce": nonce, "key_id": proof.keyId, "attestation": proof.attestation],
            refreshCookie: nil
        )
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let receipt = object["receipt"] as? String else {
            throw AtlasError.transport("The server did not accept the attestation.")
        }
        return AppAttestRegistration(receipt: receipt, expiresAt: (object["expires_at"] as? Int64) ?? 0)
    }
}

#if canImport(DeviceCheck) && !os(macOS)
import CryptoKit
import DeviceCheck

/// Apple's on-device half of attestation, wired to ``AtlasClient``.
///
/// ```swift
/// let appAttest = AtlasAppAttest()
/// let reg = try await client.registerAppAttestKey(attest: appAttest.attest)
/// client.attestationProvider = { nonce in
///     .appAttest(assertion: try await appAttest.assert(nonce: nonce), receipt: reg.receipt)
/// }
/// ```
@available(iOS 14.0, tvOS 15.0, watchOS 9.0, visionOS 1.0, *)
public final class AtlasAppAttest: @unchecked Sendable {
    private let service = DCAppAttestService.shared
    private var keyId: String?

    public init() {}

    public var isSupported: Bool { service.isSupported }

    /// Generates a key and attests it for `challenge` (SHA-256 of it is the client-data hash).
    public func attest(challenge: String) async throws -> (keyId: String, attestation: String) {
        let id = try await service.generateKey()
        let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let object = try await service.attestKey(id, clientDataHash: hash)
        keyId = id
        return (id, object.base64EncodedString())
    }

    /// Signs `nonce` with the attested key; the base64 assertion goes in ``AtlasAttestationProof/appAttest(assertion:receipt:)``.
    public func assert(nonce: String) async throws -> String {
        guard let id = keyId else { throw AtlasError.transport("Register an App Attest key first.") }
        let hash = Data(SHA256.hash(data: Data(nonce.utf8)))
        return try await service.generateAssertion(id, clientDataHash: hash).base64EncodedString()
    }
}

/// The DeviceCheck fallback: available on every OS version this package supports.
@available(iOS 11.0, tvOS 11.0, watchOS 9.0, visionOS 1.0, *)
public enum AtlasDeviceCheck {
    /// The `DCDevice` token for devices where App Attest is unavailable.
    public static func proof() async throws -> AtlasAttestationProof {
        guard DCDevice.current.isSupported else { throw AtlasError.transport("DeviceCheck is not supported on this device.") }
        let token: Data = try await withCheckedThrowingContinuation { c in
            DCDevice.current.generateToken { data, error in
                if let data { c.resume(returning: data) } else { c.resume(throwing: error ?? AtlasError.transport("No DeviceCheck token.")) }
            }
        }
        return .deviceCheck(token: token.base64EncodedString())
    }
}
#endif
