import Foundation

/// Device sign-in approval (OAuth 2.0 Device Authorization Grant, RFC 8628) from
/// a signed-in phone: the user types — or scans — the code a TV, watch or CLI
/// shows, and this app approves it instead of sending them to Atlas's hosted
/// `/oauth2/device` page. The calls present the stored session.

/// One requested scope of a ``PendingDeviceAuthorization``, with a human description.
public struct DeviceAuthorizationScope: Decodable, Sendable, Equatable {
    public let scope: String
    public let description: String

    enum CodingKeys: String, CodingKey { case scope, description }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

/// A pending device sign-in: the code a TV, watch or CLI shows.
public struct PendingDeviceAuthorization: Decodable, Sendable, Equatable {
    /// The client (device app) asking to sign in.
    public struct Client: Decodable, Sendable, Equatable {
        public let clientId: String?
        public let name: String
        public let logoURL: String?
        public let homepageURL: String?
        public let firstParty: Bool

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case name
            case logoURL = "logo_url"
            case homepageURL = "homepage_url"
            case firstParty = "first_party"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            logoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            homepageURL = try c.decodeIfPresent(String.self, forKey: .homepageURL)
            firstParty = try c.decodeIfPresent(Bool.self, forKey: .firstParty) ?? false
        }
    }

    public let id: String
    /// The code as the device shows it (`XXXX-XXXX`).
    public let userCode: String
    /// `pending`, `approved` or `denied`.
    public let status: String
    public let client: Client
    public let scopes: [DeviceAuthorizationScope]
    /// The API the device asked a token for, if any.
    public let audience: String?
    /// Approving needs a recent re-authentication.
    public let requiresStepUp: Bool
    public let createdAt: Int?
    public let expiresAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, client, scopes, audience
        case userCode = "user_code"
        case requiresStepUp = "requires_step_up"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userCode = try c.decodeIfPresent(String.self, forKey: .userCode) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        client = try c.decode(Client.self, forKey: .client)
        scopes = try c.decodeIfPresent([DeviceAuthorizationScope].self, forKey: .scopes) ?? []
        audience = try c.decodeIfPresent(String.self, forKey: .audience)
        requiresStepUp = try c.decodeIfPresent(Bool.self, forKey: .requiresStepUp) ?? false
        createdAt = try c.decodeIfPresent(Int.self, forKey: .createdAt)
        expiresAt = try c.decodeIfPresent(Int.self, forKey: .expiresAt)
    }
}

extension AtlasClient {
    /// Normalise what a person typed into the `XXXX-XXXX` form devices show:
    /// uppercase, spaces and dashes ignored. Returns the trimmed input unchanged
    /// when it is not 8 letters or digits.
    public static func formatUserCode(_ input: String) -> String {
        let cleaned = input.uppercased().filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        guard cleaned.count == 8 else { return input.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "\(cleaned.prefix(4))-\(cleaned.suffix(4))"
    }

    /// The `user_code` of a verification URL a device displayed (`?user_code=`,
    /// e.g. from its QR code), formatted; nil when there is none.
    public static func userCodeFromURL(_ url: URL) -> String? {
        guard url.scheme != nil,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "user_code" })?.value,
              !value.isEmpty
        else { return nil }
        return formatUserCode(value)
    }

    /// Look up a pending device sign-in by the code a TV, watch or CLI shows
    /// (`POST /v1/client/me/device_authorizations/lookup`). Show the client and
    /// scopes, then ``approveDeviceAuthorization(_:)`` or
    /// ``denyDeviceAuthorization(_:)``.
    public func lookupDeviceAuthorization(userCode: String) async throws -> PendingDeviceAuthorization {
        try await authedDecode(
            PendingDeviceAuthorization.self, "POST", "/v1/client/me/device_authorizations/lookup",
            json: ["user_code": AtlasClient.formatUserCode(userCode)]
        )
    }

    /// Approve the device sign-in for the signed-in user; the device's next poll
    /// receives its tokens. When the application requires a recent
    /// re-authentication this throws an ``AtlasError`` with code
    /// `STEP_UP_REQUIRED` — re-authenticate, then approve again.
    @discardableResult
    public func approveDeviceAuthorization(_ authorization: PendingDeviceAuthorization) async throws -> PendingDeviceAuthorization {
        try await decideDeviceAuthorization(authorization, "approve")
    }

    /// Deny the device sign-in; the device's next poll is told `access_denied`.
    @discardableResult
    public func denyDeviceAuthorization(_ authorization: PendingDeviceAuthorization) async throws -> PendingDeviceAuthorization {
        try await decideDeviceAuthorization(authorization, "deny")
    }

    private func decideDeviceAuthorization(_ authorization: PendingDeviceAuthorization, _ decision: String) async throws -> PendingDeviceAuthorization {
        let id = authorization.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? authorization.id
        return try await authedDecode(
            PendingDeviceAuthorization.self, "POST", "/v1/client/me/device_authorizations/\(id)/\(decision)",
            json: ["user_code": authorization.userCode]
        )
    }
}
