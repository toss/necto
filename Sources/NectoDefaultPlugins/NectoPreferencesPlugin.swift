//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoSDK
import Foundation

/// What the app has stored in `UserDefaults`, read from Necto.
///
/// Unlike the plugins that need the app to report to them, this one needs nothing:
/// register it and it answers, because the store it reads is already there.
///
/// ```swift
/// NectoSDK.register(NectoPreferencesPlugin())
/// ```
///
/// A suite can be named for apps that keep their own, and the standard store is always
/// available under `standard`.
public final class NectoPreferencesPlugin: NectoPluginable, @unchecked Sendable {
    /// Enough of a value to recognise a row by. The whole thing is behind `detail`,
    /// because a token or a cached response is not something to put in a list.
    static let previewLimit = 120

    public let id = "preferences"

    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module, subdirectory: "Panels/preferences") }


    /// Named stores this plugin will open, beyond `standard`. An app that keeps its
    /// preferences in an app group passes the suite name here.
    private let suites: [String]

    public init(suites: [String] = []) {
        self.suites = suites
    }

    public func register(_ necto: NectoHandler) {
        necto.handle("preferences.list") { [self] input in
            let defaults = try store(named: input["suite"]?.stringValue)
            let prefix = input["prefix"]?.stringValue ?? ""

            let entries = defaults.dictionaryRepresentation()
                .filter { prefix.isEmpty || $0.key.hasPrefix(prefix) }
                .sorted { $0.key < $1.key }
                .map { Self.summary(key: $0.key, value: $0.value) }

            return ["entries": .array(entries), "total": .number(Double(defaults.dictionaryRepresentation().count))]
        }

        necto.handle("preferences.detail") { [self] input in
            let key = try Self.requiredKey(input)
            let defaults = try store(named: input["suite"]?.stringValue)
            guard let value = defaults.object(forKey: key) else {
                throw NectoBridgeError(code: .operationUnavailable, message: "No key '\(key)'")
            }
            return ["entry": Self.detail(key: key, value: value)]
        }

        necto.handle("preferences.suites") { [self] _ in
            ["suites": .array((["standard"] + suites).map(NectoJSONValue.string))]
        }

        // Writing into a store a running app is reading from can change what it does
        // next. The name says so; a panel that wants to ask does the asking.
        necto.handle("preferences.set") { [self] input in
            let key = try Self.requiredKey(input)
            guard let value = input["value"] else {
                throw NectoBridgeError(code: .invalidInput, message: "value is required")
            }
            let defaults = try store(named: input["suite"]?.stringValue)
            defaults.set(try Self.plain(value, as: input["type"]?.stringValue), forKey: key)
            return ["entry": Self.detail(key: key, value: defaults.object(forKey: key) ?? NSNull())]
        }

        necto.handle("preferences.remove") { [self] input in
            let key = try Self.requiredKey(input)
            try store(named: input["suite"]?.stringValue).removeObject(forKey: key)
            return ["removed": .bool(true)]
        }
    }

    /// The standard store, or a named one the app said it keeps.
    ///
    /// A suite this plugin was not told about is refused rather than opened: a panel
    /// that can name any suite can read any app group the app can.
    private func store(named suite: String?) throws -> UserDefaults {
        guard let suite, suite != "standard" else { return .standard }
        guard suites.contains(suite), let defaults = UserDefaults(suiteName: suite) else {
            throw NectoBridgeError(code: .invalidInput, message: "This app does not offer the suite '\(suite)'")
        }
        return defaults
    }

    // MARK: Coding

    private static func requiredKey(_ input: NectoJSONValue) throws -> String {
        guard let key = input["key"]?.stringValue, !key.isEmpty else {
            throw NectoBridgeError(code: .invalidInput, message: "key must be a non-empty string")
        }
        return key
    }

    /// What a row needs: enough to recognise, not enough to be the value.
    static func summary(key: String, value: Any) -> NectoJSONValue {
        let rendered = describe(value)
        return [
            "key": .string(key),
            "type": .string(typeName(value)),
            "preview": .string(String(rendered.prefix(previewLimit))),
            "isTruncated": .bool(rendered.count > previewLimit),
        ]
    }

    static func detail(key: String, value: Any) -> NectoJSONValue {
        [
            "key": .string(key),
            "type": .string(typeName(value)),
            "value": .string(describe(value)),
        ]
    }

    /// Named for what someone reading the list would call it. `Bool` before `Int`
    /// because `NSNumber` says yes to both and the narrower answer is the true one.
    static func typeName(_ value: Any) -> String {
        switch value {
        case is String: "String"
        case is Data: "Data"
        case is Date: "Date"
        case is [Any]: "Array"
        case is [String: Any]: "Dictionary"
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID()
                ? "Bool"
                : (CFNumberIsFloatType(number) ? "Double" : "Int")
        default: String(describing: type(of: value))
        }
    }

    /// One line for simple values, JSON for the rest. Data is described rather than
    /// rendered: a panel showing 40 kB of base64 is showing nothing.
    ///
    /// Containers are pretty-printed because this string is also what the editor opens.
    static func describe(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let data as Data:
            return "\(data.count) bytes"
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID()
                ? (number.boolValue ? "true" : "false")
                : number.stringValue
        default:
            guard let jsonValue = NectoJSONValue(foundationValue: value) else {
                return String(describing: value)
            }
            return (try? jsonValue.jsonString(options: [.sortedKeys, .prettyPrinted]))
                ?? String(describing: value)
        }
    }

    /// `plain(_:)` with the type the store had. JSON numbers are all Double and JSON
    /// has no date at all, so without the hint a saved Int comes back a Double and a
    /// saved Date comes back a String — silently, and only visible on the next read.
    static func plain(_ value: NectoJSONValue, as hint: String?) throws -> Any {
        switch (hint, value) {
        case let ("Int", .number(number)):
            return Int(number)
        case let ("Date", .string(text)):
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw NectoBridgeError(code: .invalidInput, message: "'\(text)' is not an ISO 8601 date")
            }
            return date
        default:
            return plain(value)
        }
    }

    /// Back to something `UserDefaults` will store.
    static func plain(_ value: NectoJSONValue) -> Any {
        switch value {
        case let .string(string): string
        case let .number(number): number
        case let .bool(bool): bool
        case let .array(values): values.map(plain)
        case let .object(fields): fields.mapValues(plain)
        case .null: NSNull()
        }
    }
}
