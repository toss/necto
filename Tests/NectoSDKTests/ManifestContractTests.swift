//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoProcessMetrics
import Foundation
import Testing

@testable import NectoDefaultPlugins
@testable import NectoSDK

/// The manifest is the contract, and the runtime validates both sides against it. So a
/// schema that does not match what the plugin actually returns is not a documentation
/// mistake — it is a plugin that fails the moment someone opens it.
///
/// These tests read the shipped manifests and run the real outputs through them.
@Suite("Manifest contracts")
struct ManifestContractTests {
    /// Repo-relative, from this file. A hard-coded path works on one machine.
    private static let manifests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // NectoSDKTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appending(path: "WebPackages/BuiltInPlugins/src")

    private func operations(of plugin: String) throws -> [String: NectoJSONValue] {
        let url = Self.manifests.appending(path: "\(plugin)/public/manifest.json")
        let manifest = try JSONDecoder().decode(NectoJSONValue.self, from: try Data(contentsOf: url))
        let listed = try #require(manifest["operations"]?.arrayValue)

        return Dictionary(uniqueKeysWithValues: listed.compactMap { operation in
            (operation["binding"]?["name"]?.stringValue).map { ($0, operation) }
        })
    }

    /// Runs one operation the way the runtime does and checks the result against the
    /// schema the manifest promised for it.
    private func check(
        _ plugin: any NectoPluginable,
        _ key: String,
        in manifest: String,
        input: NectoJSONValue = [:]
    ) async throws {
        let operation = try #require(try operations(of: manifest)[key], "\(key) is not in the manifest")

        let collector = NectoHandler()
        plugin.register(collector)
        guard case let .once(body)? = collector.registrations["\(key)@1"]?.body else {
            Issue.record("\(key) is not a once-and-done handler")
            return
        }

        let output = try await body(input)
        if let failure = NectoJSONSchema.validate(output, against: try #require(operation["outputSchema"])) {
            Issue.record("\(key) returned something its own manifest rejects: \(failure)")
        }
    }

    @Test("what the events plugin returns is what its manifest promised")
    func eventsMatchTheirManifest() async throws {
        let plugin = NectoEventsPlugin()
        let event = NectoEvent(level: .warn, tag: "Cache", message: "evicted", detail: ["freed": "3.2 MB"])
        plugin.report(event)

        try await check(plugin, "necto.device.events.list", in: "event-log")
        try await check(plugin, "necto.device.events.detail", in: "event-log", input: ["eventID": .string(event.id)])
        try await check(plugin, "necto.device.events.clear", in: "event-log")
    }

    @Test("what the network plugin returns is what its manifest promised")
    func recordsMatchTheirManifest() async throws {
        let plugin = NectoNetworkPlugin()
        let record = NectoNetworkRecord(
            id: "r1",
            method: "GET",
            url: "https://api.example.com/v2/posts",
            startedAtMilliseconds: 1_772_000_000_000,
            state: .completed,
            statusCode: 200,
            durationMilliseconds: 103,
            responseByteCount: 68
        )
        plugin.report(record)

        try await check(plugin, "necto.device.network-records.list", in: "network-logger")
        try await check(plugin, "necto.device.network-records.detail", in: "network-logger", input: ["recordID": .string("r1")])
        try await check(plugin, "necto.device.network-records.clear", in: "network-logger")
    }

    @Test("what the performance plugin returns is what its manifest promised")
    func performanceMatchesItsManifest() async throws {
        let plugin = NectoPerformancePlugin(metrics: [
            NectoMetric(id: "memory", title: "Memory", unit: "MB"),
            NectoMetric(id: "fps", title: "Frame rate", unit: "fps", budget: .atLeast(55)),
        ])

        // Once with nothing recorded, because `latest` is null until the first reading
        // and that is the shape a panel sees when it opens first.
        try await check(plugin, "necto.device.performance.series", in: "performance-monitor")

        plugin.report(148, for: "memory")
        plugin.report(48.2, for: "fps")
        try await check(plugin, "necto.device.performance.metrics", in: "performance-monitor")
        try await check(plugin, "necto.device.performance.series", in: "performance-monitor")

        let process = ProcessPerformancePlugin()
        try await check(process, "necto.device.performance.snapshot", in: "performance-monitor")
        try await check(process, "necto.device.performance.memory", in: "performance-monitor")
    }

    @Test("what the preferences plugin returns is what its manifest promised")
    func preferencesMatchTheirManifest() async throws {
        let suiteName = "necto.tests.contract.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("dark", forKey: "theme")
        defaults.set(47, forKey: "count")

        let plugin = NectoPreferencesPlugin(suites: [suiteName])
        let suite: NectoJSONValue = ["suite": .string(suiteName)]

        try await check(plugin, "necto.device.preferences.list", in: "preferences", input: suite)
        try await check(
            plugin,
            "necto.device.preferences.detail",
            in: "preferences",
            input: ["suite": .string(suiteName), "key": "theme"]
        )
        try await check(plugin, "necto.device.preferences.suites", in: "preferences")
        try await check(
            plugin,
            "necto.device.preferences.set",
            in: "preferences",
            input: ["suite": .string(suiteName), "key": "count", "value": .number(48)]
        )
        try await check(
            plugin,
            "necto.device.preferences.remove",
            in: "preferences",
            input: ["suite": .string(suiteName), "key": "count"]
        )
    }

    @Test("what the files plugin returns is what its manifest promised")
    func filesMatchTheirManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "necto-files-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appending(path: "note.txt"))

        let plugin = NectoFilesPlugin(roots: [.init(id: "test", name: "Test", url: root)])
        try await check(plugin, "necto.device.files.roots", in: "files")
        try await check(plugin, "necto.device.files.list", in: "files", input: ["root": "test"])
        try await check(plugin, "necto.device.files.preview", in: "files", input: ["root": "test", "path": "note.txt"])
        try await check(plugin, "necto.device.files.info", in: "files", input: ["root": "test", "path": "note.txt"])
        try await check(
            plugin,
            "necto.device.files.write",
            in: "files",
            input: ["root": "test", "path": "note.txt", "content": "updated"]
        )
        try await check(plugin, "necto.device.files.delete", in: "files", input: ["root": "test", "path": "note.txt"])
    }

    @Test("what the view inspector returns is what its manifest promised")
    func viewsMatchTheirManifest() async throws {
        let plugin = DefaultViewInspectorPlugin {
            [NectoViewNode(
                className: "UIWindow",
                frame: (0, 0, 393, 852),
                children: [NectoViewNode(className: "UILabel", text: "Hi", frame: (0, 0, 100, 20), alpha: 0.5)]
            )]
        }
        try await check(plugin, "necto.device.views.tree", in: "view-inspector")
        try await check(plugin, "necto.device.views.search", in: "view-inspector", input: ["query": "Hi"])
        try await check(plugin, "necto.device.views.inspect", in: "view-inspector", input: ["viewID": "path:0"])
        let collector = NectoHandler()
        plugin.register(collector)
        guard case let .once(snapshot)? = collector.registrations["necto.device.views.snapshot@1"]?.body else {
            Issue.record("views.snapshot is not registered")
            return
        }
        let baseline = try await snapshot([:])
        let snapshotID = try #require(baseline["snapshotID"]?.stringValue)
        try await check(plugin, "necto.device.views.snapshot", in: "view-inspector")
        try await check(
            plugin,
            "necto.device.views.compare",
            in: "view-inspector",
            input: ["baselineSnapshotID": .string(snapshotID)]
        )

        let interactions = DefaultViewInspectorPlugin(snapshot: { [] }) { operation, _ in
            switch operation {
            case "highlight": ["highlighted": true]
            case "tap": ["tapped": true, "method": "primaryAction"]
            case "tapAt": ["tapped": true, "method": "primaryAction", "x": 10, "y": 20]
            case "scroll": ["offset": [0, 100]]
            case "swipe", "drag": ["offset": [0, 100], "method": "contentOffset"]
            case "longPress": ["pressed": true, "duration": 0.6, "method": "controlEvents"]
            case "inputText": ["inserted": true, "length": 5, "method": "UIKeyInput"]
            default: throw NectoBridgeError(code: .operationUnavailable, message: operation)
            }
        }
        try await check(interactions, "necto.device.views.highlight", in: "view-inspector", input: ["viewID": "v"])
        try await check(interactions, "necto.device.views.tap", in: "view-inspector", input: ["viewID": "v"])
        try await check(interactions, "necto.device.views.tapAt", in: "view-inspector", input: ["x": 10, "y": 20])
        try await check(interactions, "necto.device.views.scroll", in: "view-inspector", input: ["viewID": "v", "direction": "down"])
        try await check(interactions, "necto.device.views.swipe", in: "view-inspector", input: ["viewID": "v", "direction": "up"])
        try await check(interactions, "necto.device.views.drag", in: "view-inspector", input: ["fromX": 10, "fromY": 20, "toX": 10, "toY": 5])
        try await check(interactions, "necto.device.views.longPress", in: "view-inspector", input: ["viewID": "v"])
        try await check(interactions, "necto.device.views.inputText", in: "view-inspector", input: ["viewID": "v", "text": "hello"])
    }

    /// A schema that says only `{"type": "object"}` passes anything, so it reads as a
    /// contract while promising nothing.
    @Test("every shipped operation says what it takes and returns", arguments: [
        "event-log", "files", "network-logger", "performance-monitor", "plugin-sample", "preferences", "shell-demo",
        "view-inspector",
    ])
    func schemasSaySomething(plugin: String) throws {
        for (key, operation) in try operations(of: plugin) {
            for side in ["inputSchema", "outputSchema"] {
                let schema = try #require(operation[side]?.objectValue, "\(key) has no \(side)")
                #expect(schema["properties"] != nil, "\(key) \(side) declares no properties")
            }
        }
    }
}
