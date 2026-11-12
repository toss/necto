//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// A partial JSON Schema implementation used to validate operation payloads.
///
/// Only the keywords below are supported. They are the minimum needed to express
/// a plugin contract, and implementing them here keeps the package dependency free.
///
/// - `type` (object, array, string, number, integer, boolean, null)
/// - `properties`, `required`, `additionalProperties` (boolean)
/// - `items`
/// - `enum`
/// - `minimum`, `maximum`
/// - `minLength`, `maxLength`
/// - `minItems`, `maxItems`
///
/// Unsupported keywords are ignored. Constraints a schema cannot express remain
/// the provider's responsibility.
public enum NectoJSONSchema {
    public struct ValidationFailure: Sendable, Hashable, Error, CustomStringConvertible {
        /// Where validation failed. Empty for the root value.
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }

        public var description: String {
            path.isEmpty ? reason : "\(path): \(reason)"
        }
    }

    /// Validates a value against a schema, reporting only the first failure.
    public static func validate(_ value: NectoJSONValue, against schema: NectoJSONValue) -> ValidationFailure? {
        validate(value, against: schema, path: "")
    }

    private static func validate(
        _ value: NectoJSONValue,
        against schema: NectoJSONValue,
        path: String
    ) -> ValidationFailure? {
        guard let schema = schema.objectValue else { return nil }

        if let type = schema["type"]?.stringValue,
           let failure = validateType(value, type: type, path: path) {
            return failure
        }

        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            return ValidationFailure(path: path, reason: "is not one of the allowed values")
        }

        switch value {
        case let .number(number):
            if let minimum = schema["minimum"]?.numberValue, number < minimum {
                return ValidationFailure(path: path, reason: "must be greater than or equal to \(minimum)")
            }
            if let maximum = schema["maximum"]?.numberValue, number > maximum {
                return ValidationFailure(path: path, reason: "must be less than or equal to \(maximum)")
            }

        case let .string(text):
            if let minLength = schema["minLength"]?.numberValue, Double(text.count) < minLength {
                return ValidationFailure(path: path, reason: "must be at least \(Int(minLength)) characters")
            }
            if let maxLength = schema["maxLength"]?.numberValue, Double(text.count) > maxLength {
                return ValidationFailure(path: path, reason: "must be at most \(Int(maxLength)) characters")
            }

        case let .array(elements):
            if let minItems = schema["minItems"]?.numberValue, Double(elements.count) < minItems {
                return ValidationFailure(path: path, reason: "must contain at least \(Int(minItems)) items")
            }
            if let maxItems = schema["maxItems"]?.numberValue, Double(elements.count) > maxItems {
                return ValidationFailure(path: path, reason: "must contain at most \(Int(maxItems)) items")
            }
            if let itemSchema = schema["items"] {
                for (index, element) in elements.enumerated() {
                    if let failure = validate(element, against: itemSchema, path: "\(path)[\(index)]") {
                        return failure
                    }
                }
            }

        case let .object(members):
            if let required = schema["required"]?.arrayValue {
                for entry in required {
                    guard let key = entry.stringValue else { continue }
                    if members[key] == nil {
                        return ValidationFailure(path: join(path, key), reason: "is required")
                    }
                }
            }

            let properties = schema["properties"]?.objectValue ?? [:]
            if schema["additionalProperties"]?.boolValue == false {
                for key in members.keys where properties[key] == nil {
                    return ValidationFailure(path: join(path, key), reason: "is not declared in the schema")
                }
            }

            for (key, propertySchema) in properties {
                guard let member = members[key] else { continue }
                if let failure = validate(member, against: propertySchema, path: join(path, key)) {
                    return failure
                }
            }

        case .null, .bool:
            break
        }

        return nil
    }

    private static func validateType(
        _ value: NectoJSONValue,
        type: String,
        path: String
    ) -> ValidationFailure? {
        let matches = switch type {
        case "object": value.objectValue != nil
        case "array": value.arrayValue != nil
        case "string": value.stringValue != nil
        case "number": value.numberValue != nil
        case "integer": value.isInteger
        case "boolean": value.boolValue != nil
        case "null": value == .null
        default: true
        }

        guard matches else {
            return ValidationFailure(path: path, reason: "must be of type \(type)")
        }
        return nil
    }

    private static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}
