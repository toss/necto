//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// A JSON value carried as plugin operation input, output or stream event.
///
/// Numbers are stored as `Double`. JSON Schema's `integer` is decided by whether
/// the stored value has no fractional part.
public enum NectoJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([NectoJSONValue])
    case object([String: NectoJSONValue])
}

public extension NectoJSONValue {
    /// Creates a JSON value from Foundation's JSON-compatible object graph.
    ///
    /// Returns `nil` when any value in the graph is not representable as JSON.
    init?(foundationValue value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            var converted: [NectoJSONValue] = []
            converted.reserveCapacity(value.count)
            for element in value {
                guard let element = Self(foundationValue: element) else { return nil }
                converted.append(element)
            }
            self = .array(converted)
        case let value as [String: Any]:
            var converted: [String: NectoJSONValue] = [:]
            converted.reserveCapacity(value.count)
            for (key, element) in value {
                guard let element = Self(foundationValue: element) else { return nil }
                converted[key] = element
            }
            self = .object(converted)
        default:
            return nil
        }
    }

    /// Returns the Foundation object graph represented by this JSON value.
    var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .number(value):
            return value
        case let .string(value):
            return value
        case let .array(value):
            return value.map(\.foundationValue)
        case let .object(value):
            return value.mapValues(\.foundationValue)
        }
    }

    /// Serializes this value without requiring each caller to configure its own encoder.
    ///
    /// `fragmentsAllowed` also supports scalar JSON values such as strings and numbers.
    /// Non-finite numbers are rejected before entering Foundation's serializer.
    func jsonData(options: JSONSerialization.WritingOptions = []) throws -> Data {
        guard hasOnlyFiniteNumbers else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: [], debugDescription: "JSON numbers must be finite")
            )
        }
        return try JSONSerialization.data(
            withJSONObject: foundationValue,
            options: options.union(.fragmentsAllowed)
        )
    }

    /// Serializes this value as UTF-8 JSON text.
    func jsonString(options: JSONSerialization.WritingOptions = []) throws -> String {
        String(decoding: try jsonData(options: options), as: UTF8.self)
    }

    private var hasOnlyFiniteNumbers: Bool {
        switch self {
        case let .number(value):
            return value.isFinite
        case let .array(values):
            return values.allSatisfy(\.hasOnlyFiniteNumbers)
        case let .object(values):
            return values.values.allSatisfy(\.hasOnlyFiniteNumbers)
        case .null, .bool, .string:
            return true
        }
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var arrayValue: [NectoJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: NectoJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Whether the value is representable as an integer, used for JSON Schema `integer`.
    var isInteger: Bool {
        guard case let .number(value) = self else { return false }
        return value.rounded() == value && value.isFinite
    }

    subscript(key: String) -> NectoJSONValue? {
        objectValue?[key]
    }
}

extension NectoJSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([NectoJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: NectoJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Bridges a `Codable` type into the JSON payloads operations exchange.
    public init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(NectoJSONValue.self, from: data)
    }

    public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

extension NectoJSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension NectoJSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension NectoJSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension NectoJSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension NectoJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension NectoJSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: NectoJSONValue...) { self = .array(elements) }
}

extension NectoJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, NectoJSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
