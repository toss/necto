//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel
import Testing

@Suite("Simulator connection and CLI", .serialized, .timeLimit(.minutes(15)))
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

    @Test("simulator SDK enforces optional public-key authentication", arguments: ConnectionSecurity.allCases)
    func securityConnection(security: ConnectionSecurity) async throws {
        let credentials = try ConnectionCredentials(security: security)
        defer { credentials.close() }
        let host = SecurityConnectionHost { bundleID in
            guard bundleID == AppFixture.exampleID else { return nil }
            return try await credentials.identity(bundleID: bundleID)
        }
        let app = try AppFixture()
        do {
            try await app.start(publicKey: credentials.publicKey) { await host.start() }
            if security == .missingKey || security == .mismatchedKey {
                let reason: NectoUnauthorizedApp.Reason = security == .missingKey ? .missingKey : .rejectedKey
                for attempt in 0..<2 {
                    try await app.wait("SDK authentication rejection") {
                        await host.center.unauthorizedApps.contains { $0.appBundleID == AppFixture.exampleID && $0.reason == reason }
                    }
                    #expect(await host.center.connectedApps.allSatisfy { $0.appBundleID != AppFixture.exampleID })
                    #expect(host.plugins.keys.allSatisfy { $0.appBundleID != AppFixture.exampleID })
                    let denied = try #require(await host.center.unauthorizedApps.first { $0.appBundleID == AppFixture.exampleID })
                    do {
                        _ = try await host.invoke("preferences.suites", input: [:], target: denied.target)
                        Issue.record("An unauthorized app accepted a plugin call")
                    } catch let error as NectoBridgeError { #expect(error.code == .unauthorized) }
                    if attempt == 0 {
                        try await app.terminateExample()
                        try await app.wait("denied app removal") {
                            await host.center.unauthorizedApps.allSatisfy { $0.appBundleID != AppFixture.exampleID }
                        }
                        try await app.launchExample()
                    }
                }
                if security == .missingKey { try credentials.installMatchingKey() }
            }
            if security != .mismatchedKey {
                var target = try await host.waitForPlugins(app)
                try await checkSecureCall(host, target: target)
                try await app.terminateExample()
                try await app.wait("SDK disconnection") {
                    await host.center.connectedApps.allSatisfy { $0.appBundleID != AppFixture.exampleID }
                        && host.plugins.keys.allSatisfy { $0.appBundleID != AppFixture.exampleID }
                }
                try await app.launchExample()
                target = try await host.waitForPlugins(app)
                try await checkSecureCall(host, target: target)
            }
            #expect(credentials.lookups.isEmpty == (security == .plaintext))
        } catch {
            await host.stop()
            await app.close()
            throw error
        }
        await host.stop()
        await app.close()
    }

    private func checkSecureCall(_ host: SecurityConnectionHost, target: NectoTarget) async throws {
        let value = NectoJSONValue.string(UUID().uuidString)
        _ = try await host.invoke("preferences.set", input: ["key": "necto.e2e.security", "value": value], target: target)
        let result = try await host.invoke("preferences.detail", input: ["key": "necto.e2e.security"], target: target)
        #expect(result["entry"]?["value"] == value)
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
