//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@Suite("Simulator connection and CLI", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ConnectionTests {
    @Test("discover plugins, call once, stream, disconnect and reconnect")
    func connectionAndPlugins() async throws {
        let app = try AppFixture()
        do {
            try await app.start()
            try await app.waitForPlugins()

            let onceHelp = try await app.json(["plugin", "help", "preferences", "preferences.detail", "--json"])
            let once = try #require(onceHelp["operation"] as? [String: Any])
            #expect(once["kind"] as? String == "once")
            #expect(once["available"] as? Bool == true)
            let input = try #require(once["inputSchema"] as? [String: Any])
            #expect((input["required"] as? [String])?.contains("key") == true)

            let streamHelp = try await app.json(["plugin", "help", "performance-monitor", "performance.observe", "--json"])
            let stream = try #require(streamHelp["operation"] as? [String: Any])
            #expect(stream["kind"] as? String == "stream")
            #expect(stream["available"] as? Bool == true)

            try await checkOnce(app)
            try await checkStream(app)

            // Observe a real event before disconnecting, so registration cannot race termination.
            let pending = try app.subscribe()
            try await app.waitForOutput(pending)
            try await app.terminateExample()
            let disconnected = try await app.finish(pending)
            #expect(disconnected.status != 0)
            #expect(!disconnected.error.isEmpty)
            try await app.waitForDevice(connected: false)

            let missing = try await app.cli(["plugin", "send", "preferences", "preferences.suites"])
            #expect(missing.status != 0)
            #expect(missing.output.isEmpty)

            try await app.launchExample()
            try await app.waitForPlugins()
            try await checkOnce(app)
            try await checkStream(app)
        } catch {
            await app.close()
            throw error
        }
        await app.close()
    }

    private func checkOnce(_ app: AppFixture) async throws {
        let value = UUID().uuidString
        let input = String(decoding: try JSONSerialization.data(withJSONObject: [
            "key": "necto.e2e.value", "value": value,
        ]), as: UTF8.self)
        _ = try await app.json(["plugin", "send", "preferences", "preferences.set", "--input", input])
        let result = try await app.json([
            "plugin", "send", "preferences", "preferences.detail", "--input", #"{"key":"necto.e2e.value"}"#,
        ])
        let entry = try #require(result["entry"] as? [String: Any])
        #expect(entry["key"] as? String == "necto.e2e.value")
        #expect(entry["value"] as? String == value)
    }

    private func checkStream(_ app: AppFixture) async throws {
        let metrics = try await app.json(["plugin", "send", "performance-monitor", "performance.metrics"])
        let ids = try #require(metrics["metrics"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        let result = try await app.finish(app.subscribe(limit: 3))
        try result.requireSuccess()
        let events = try result.output.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(events.count == 3)
        for event in events {
            #expect(ids.contains(try #require(event["metricID"] as? String)))
            let sample = try #require(event["sample"] as? [String: Any])
            #expect(try #require(sample["at"] as? Double) > 0)
            #expect(try #require(sample["value"] as? Double).isFinite)
        }
    }
}
