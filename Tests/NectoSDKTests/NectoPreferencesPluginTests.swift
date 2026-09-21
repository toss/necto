//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoDefaultPlugins
@testable import NectoSDK

/// Runs a plugin's registration the way the runtime does.
private func call(
    _ plugin: any NectoPluginable,
    _ name: String,
    _ input: NectoJSONValue = [:]
) async throws -> NectoJSONValue {
    let collector = NectoHandler()
    plugin.register(collector)
    guard case let .once(body)? = collector.registrations["necto.device.\(name)@1"]?.body else {
        throw NectoBridgeError(code: .operationUnavailable, message: name)
    }
    return try await body(input)
}

@Suite("Preferences plugin")
struct NectoPreferencesPluginTests {
    /// A suite of its own, so a test never reads or writes the machine's real defaults.
    private func makeSuite() -> (name: String, defaults: UserDefaults) {
        let name = "necto.tests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test("reads what the app already stored")
    func readsExistingKeys() async throws {
        let suite = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite.name) }
        suite.defaults.set("dark", forKey: "com.example.theme")

        let plugin = NectoPreferencesPlugin(suites: [suite.name])
        let output = try await call(plugin, "preferences.list", ["suite": .string(suite.name), "prefix": "com.example"])

        let entry = try #require(output["entries"]?.arrayValue?.first)
        #expect(entry["key"]?.stringValue == "com.example.theme")
        #expect(entry["type"]?.stringValue == "String")
        #expect(entry["preview"]?.stringValue == "dark")
    }

    /// `NSNumber` answers to both, and the narrower answer is the true one.
    @Test("tells a Bool from an Int")
    func distinguishesBoolFromInt() {
        #expect(NectoPreferencesPlugin.typeName(true) == "Bool")
        #expect(NectoPreferencesPlugin.typeName(47) == "Int")
        #expect(NectoPreferencesPlugin.typeName(1.5) == "Double")
        #expect(NectoPreferencesPlugin.describe(false) == "false")
    }

    /// Property-list containers may contain values such as `Date` that JSON does not.
    /// Reading preferences must still return a preview instead of terminating the app.
    @Test("describes a property-list container that is not JSON")
    func describesNonJSONPropertyListContainer() {
        let rendered = NectoPreferencesPlugin.describe([
            "createdAt": Date(timeIntervalSince1970: 0),
        ])

        #expect(rendered.contains("createdAt"))
    }

    /// A list of two hundred keys should not carry two hundred values, and one of them
    /// is usually a token.
    @Test("keeps a long value out of the list and says it did")
    func previewIsTrimmed() async throws {
        let suite = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite.name) }
        let token = String(repeating: "e", count: 400)
        suite.defaults.set(token, forKey: "token")

        let plugin = NectoPreferencesPlugin(suites: [suite.name])
        let row = try #require(
            try await call(plugin, "preferences.list", ["suite": .string(suite.name)])["entries"]?.arrayValue?
                .first { $0["key"]?.stringValue == "token" }
        )
        #expect(row["preview"]?.stringValue?.count == NectoPreferencesPlugin.previewLimit)
        #expect(row["isTruncated"] == .bool(true))

        let detail = try await call(
            plugin,
            "preferences.detail",
            ["suite": .string(suite.name), "key": "token"]
        )
        #expect(detail["entry"]?["value"]?.stringValue == token)
    }

    /// A panel that can name any suite can read any app group the app can, so it may
    /// only name the ones the app said it keeps.
    @Test("refuses a suite the app never offered")
    func refusesAnUnofferedSuite() async {
        let plugin = NectoPreferencesPlugin()
        await #expect(throws: NectoBridgeError.self) {
            try await call(plugin, "preferences.list", ["suite": "group.someone.else"])
        }
    }

    @Test("writes and removes")
    func writing() async throws {
        let suite = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite.name) }

        let plugin = NectoPreferencesPlugin(suites: [suite.name])
        _ = try await call(plugin, "preferences.set", [
            "suite": .string(suite.name), "key": "launchCount", "value": .number(47),
        ])
        #expect(suite.defaults.integer(forKey: "launchCount") == 47)

        _ = try await call(plugin, "preferences.remove", ["suite": .string(suite.name), "key": "launchCount"])
        #expect(suite.defaults.object(forKey: "launchCount") == nil)
    }

    /// JSON numbers are all Double and JSON has no date, so a round trip through the
    /// wire must not quietly change what type a key is.
    @Test("keeps a key's type across an edit")
    func keepsTypesAcrossAnEdit() async throws {
        let suite = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite.name) }
        let plugin = NectoPreferencesPlugin(suites: [suite.name])

        _ = try await call(plugin, "preferences.set", [
            "suite": .string(suite.name), "key": "count", "value": .number(47), "type": "Int",
        ])
        _ = try await call(plugin, "preferences.set", [
            "suite": .string(suite.name), "key": "when", "value": "2026-07-29T16:38:02Z", "type": "Date",
        ])

        let count = try await call(plugin, "preferences.detail", ["suite": .string(suite.name), "key": "count"])
        #expect(count["entry"]?["type"]?.stringValue == "Int")
        let when = try await call(plugin, "preferences.detail", ["suite": .string(suite.name), "key": "when"])
        #expect(when["entry"]?["type"]?.stringValue == "Date")
        #expect(when["entry"]?["value"]?.stringValue == "2026-07-29T16:38:02Z")
    }

    @Test("refuses a date that is not one")
    func refusesABadDate() async {
        let plugin = NectoPreferencesPlugin()
        await #expect(throws: NectoBridgeError.self) {
            try await call(plugin, "preferences.set", ["key": "when", "value": "yesterday-ish", "type": "Date"])
        }
    }

    @Test("says which stores it can open")
    func listsItsSuites() async throws {
        let plugin = NectoPreferencesPlugin(suites: ["group.com.example"])
        let output = try await call(plugin, "preferences.suites")
        #expect(output["suites"]?.arrayValue == [.string("standard"), .string("group.com.example")])
    }

    @Test("says so when asked for a key it does not have")
    func unknownKey() async {
        let plugin = NectoPreferencesPlugin()
        await #expect(throws: NectoBridgeError.self) {
            try await call(plugin, "preferences.detail", ["key": "nothing-like-this"])
        }
    }
}
