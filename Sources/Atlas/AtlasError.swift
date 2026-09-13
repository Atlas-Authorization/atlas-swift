import Foundation

/// One item of the §9.1 error envelope: `{ errors: [{ code, message, param?, meta? }] }`.
///
/// The API writes `message` for humans, so it is surfaced verbatim. `param`
/// attaches the message to a field so a form can render it inline rather than
/// dumping everything into a single banner.
public struct AtlasErrorItem: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let param: String?

    public init(code: String, message: String, param: String? = nil) {
        self.code = code
        self.message = message
        self.param = param
    }
}

/// Every failure the SDK can surface, kept as one type so a caller has exactly
/// one thing to catch.
///
/// `.api` is the server's §9.1 envelope with the HTTP status. `.transport`
/// wraps a URLSession/network failure. `.decoding` is a malformed body — a
/// contract drift worth distinguishing from a network drop. `.notSignedIn` is
/// raised locally before a request is even attempted, when an authenticated
/// call has no stored session to present.
public enum AtlasError: Error, Sendable {
    case api(status: Int, errors: [AtlasErrorItem])
    case transport(String)
    case decoding(String)
    case notSignedIn

    /// The first server error code, the value most callers branch on
    /// (`form_password_incorrect`, `form_identifier_not_found`, …).
    public var code: String? {
        if case let .api(_, errors) = self { return errors.first?.code }
        return nil
    }

    /// The HTTP status for an `.api` error; nil for local/transport failures.
    public var status: Int? {
        if case let .api(status, _) = self { return status }
        return nil
    }

    /// A human-readable message, always non-nil so it can go straight to a UI.
    public var message: String {
        switch self {
        case let .api(status, errors):
            return errors.first?.message ?? "The request failed (HTTP \(status))."
        case let .transport(detail):
            return detail
        case let .decoding(detail):
            return detail
        case .notSignedIn:
            return "You must be signed in."
        }
    }
}

extension AtlasError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Decode the §9.1 envelope from a non-2xx body. Falls back to a synthetic item
/// when the body is not the expected shape (a proxy error page, an empty 500),
/// so a caller always gets a code to branch on rather than a decode crash.
func parseErrorEnvelope(status: Int, data: Data) -> AtlasError {
    struct Envelope: Decodable { let errors: [AtlasErrorItem] }
    if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), !envelope.errors.isEmpty {
        return .api(status: status, errors: envelope.errors)
    }
    return .api(
        status: status,
        errors: [AtlasErrorItem(code: "unexpected", message: "The request failed (HTTP \(status)).")]
    )
}
