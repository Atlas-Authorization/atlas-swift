import Foundation

/// A minimal JSON value, so `public_metadata` / `unsafe_metadata` — arbitrary
/// customer-defined shapes — round-trip through Codable without pulling in a
/// third-party `AnyCodable`. Keeps the package dependency-free.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// The underlying string when this value is a string, else nil — the common
    /// read for a metadata field.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// A Foundation object (`String`/`NSNumber`/`[String: Any]`/`[Any]`/`NSNull`)
    /// suitable for `JSONSerialization`, so customer-defined metadata can be sent
    /// on a PATCH body without a second serialization model.
    public var foundationValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues { $0.foundationValue }
        case let .array(value): return value.map { $0.foundationValue }
        case .null: return NSNull()
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// The metadata map as a `JSONSerialization`-ready `[String: Any]`.
    var foundationObject: [String: Any] { mapValues { $0.foundationValue } }
}
