//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel
import Testing

@Suite("Native usage events")
@MainActor
struct NectoUsageLoggerTests {
    private final class Receiver: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [NectoEvent] = []

        func accept(_ event: NectoEvent) {
            lock.withLock { received.append(event) }
        }

        var events: [NectoEvent] { lock.withLock { received } }

        func waitForEvents(_ count: Int) async throws -> [NectoEvent] {
            let deadline = ContinuousClock.now + .seconds(5)
            while events.count < count {
                try #require(ContinuousClock.now < deadline, "Timed out waiting for native events")
                await Task.yield()
            }
            let snapshot = events
            #expect(snapshot.count == count)
            return snapshot
        }
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "necto-usage-\(UUID())")
        let dispatcher = NectoEventDispatcher(installationID: "test-installation", nectoVersion: "1.0.0")
        let receiver = Receiver()

        var tool: URL { root.appending(path: "necto-cli") }
        var bin: URL { root.appending(path: "bin") }

        @MainActor
        func makeLogger() -> NectoUsageLogger {
            NectoUsageLogger(
                eventDispatcher: dispatcher, diagnostics: NectoDiagnosticsLog(),
                cliInstaller: NectoCLIInstaller(tool: tool, directory: bin),
                agentSkills: NectoAgentSkills(tool: tool, home: root)
            )
        }

        func installCLILinks() throws {
            let files = FileManager.default
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            for name in ["necto", "necto-cli"] {
                try files.createSymbolicLink(at: bin.appending(path: name), withDestinationURL: tool)
            }
        }

        func installSkill(_ agent: NectoAgentSkills.Agent) throws {
            let files = FileManager.default
            let skill = root.appending(path: agent.skillPath)
            try files.createDirectory(at: root.appending(path: agent.configurationDirectory), withIntermediateDirectories: true)
            try files.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Synthetic test skill".utf8).write(to: skill)
        }

        func package(_ id: String, type: NectoPluginType? = nil, source: NectoInstalledPackage.Source = .installed)
            -> NectoInstalledPackage {
            let manifest = NectoPluginManifest(
                type: type, id: id, name: "Fixture", description: "Native usage fixture", version: "2.3.4",
                author: "Example", icon: .init(systemName: "testtube.2"), assets: ["index.html"],
                allowedOrigins: ["self"], operations: []
            )
            let archive = NectoPanelArchive(files: [.init(path: "index.html", data: Data())])
            return NectoInstalledPackage(manifest: manifest, rootURL: root, source: source, archive: archive,
                                         contentIdentity: archive.contentHash)
        }

        func removeFiles() { try? FileManager.default.removeItem(at: root) }
    }

    private func expectNativeEnvelope(_ event: NectoEvent, relatedPluginID: String? = nil) {
        #expect(event.source == .necto(relatedPluginID: relatedPluginID))
        #expect(event.jsonValue["origin"] == "necto")
        #expect(event.jsonValue["relatedPluginId"] == relatedPluginID.map(NectoJSONValue.string))
        #expect(event.jsonValue["pluginId"] == nil)
        #expect(event.jsonValue["pluginVersion"] == nil)
        #expect(event.jsonValue["channel"] == nil)
    }

    @Test("Settings opening refreshes installation status and exports only the approved snapshot")
    func settingsSnapshot() async throws {
        let fixture = Fixture()
        defer { fixture.removeFiles() }
        let logger = fixture.makeLogger()
        try await fixture.dispatcher.registerExporter(receive: fixture.receiver.accept)

        logger.settingsOpened(page: .general)
        try fixture.installCLILinks()
        try fixture.installSkill(.codex)
        logger.settingsOpened(page: .shellAccess)
        try FileManager.default.removeItem(at: fixture.bin.appending(path: "necto-cli"))
        try fixture.installSkill(.claude)
        logger.settingsOpened(page: .plugins)
        logger.settingsOpened(page: .eventExporter)
        logger.settingsOpened(page: .diagnostics)

        let events = try await fixture.receiver.waitForEvents(5)
        let snapshots = [
            ("general", false, false, false),
            ("shellAccess", true, true, false),
            ("plugins", false, true, true),
            ("eventExporter", false, true, true),
            ("diagnostics", false, true, true),
        ]
        for (page, cli, codex, claude) in snapshots {
            let event = try #require(events.first { $0.input.params["page"] == .string(page) })
            expectNativeEnvelope(event)
            #expect(event.input.eventName == "necto.settings.opened")
            #expect(event.input.params == [
                "page": .string(page),
                "languagePreference": .string(NectoL10n.language.rawValue),
                "displayLanguage": .string(NectoL10n.languageCode),
                "cliInstalled": .bool(cli),
                "codexSkillInstalled": .bool(codex),
                "claudeSkillInstalled": .bool(claude),
            ])
        }
    }

    @Test("Language events carry the selected preference and effective display language")
    func languageChanged() async throws {
        let fixture = Fixture()
        let logger = fixture.makeLogger()
        try await fixture.dispatcher.registerExporter(receive: fixture.receiver.accept)
        let language = NectoL10n.language
        let displayLanguage = NectoL10n.languageCode

        logger.languageChanged(to: language)

        let events = try await fixture.receiver.waitForEvents(1)
        let event = try #require(events.first)
        expectNativeEnvelope(event)
        #expect(event.input.eventName == "necto.setting.changed")
        #expect(event.input.params == [
            "setting": "language", "value": .string(language.rawValue), "displayLanguage": .string(displayLanguage),
        ])
    }

    @Test("Skill completion exposes the agent, action and result")
    func skillCompletion() async throws {
        let fixture = Fixture()
        let logger = fixture.makeLogger()
        try await fixture.dispatcher.registerExporter(receive: fixture.receiver.accept)

        logger.agentSkillInstallCompleted(agent: .codex, result: .init(isUpdate: false, succeeded: true))
        logger.agentSkillInstallCompleted(agent: .codex, result: .init(isUpdate: true, succeeded: false))
        logger.agentSkillInstallCompleted(agent: .claude, result: .init(isUpdate: false, succeeded: false))
        logger.agentSkillInstallCompleted(agent: .claude, result: .init(isUpdate: true, succeeded: true))

        let events = try await fixture.receiver.waitForEvents(4)
        for event in events {
            expectNativeEnvelope(event)
            #expect(event.input.eventName == "necto.agent_skill.install_completed")
        }
        let params = events.map(\.input.params)
        #expect(params.contains(["agent": "codex", "action": "install", "result": "success"]))
        #expect(params.contains(["agent": "codex", "action": "update", "result": "failure"]))
        #expect(params.contains(["agent": "claude", "action": "install", "result": "failure"]))
        #expect(params.contains(["agent": "claude", "action": "update", "result": "success"]))
    }

    @Test("Panel and package actions are native events subject to related-plugin exclusions")
    func pluginActions() async throws {
        let fixture = Fixture()
        let logger = fixture.makeLogger()
        try await fixture.dispatcher.registerExporter(receive: fixture.receiver.accept)
        let desktop = fixture.package("com.example.desktop")
        let device = fixture.package("com.example.device", source: .device(appName: "Fixture", appBundleID: "com.example.app"))
        let exporter = fixture.package("com.example.exporter", type: .eventExporter)

        logger.pluginOpened(.init(package: desktop))
        logger.pluginOpened(.init(package: device))
        logger.pluginInstalled(desktop)
        logger.pluginRemoved(desktop)
        logger.pluginInstalled(exporter)
        logger.pluginRemoved(exporter)
        logger.pluginEnabledChanged(id: desktop.id, enabled: true)
        logger.pluginEnabledChanged(id: desktop.id, enabled: false)

        let events = try await fixture.receiver.waitForEvents(8)
        let pluginParams: [String: NectoJSONValue] = ["pluginVersion": "2.3.4", "packageType": "plugin"]
        let exporterParams: [String: NectoJSONValue] = ["pluginVersion": "2.3.4", "packageType": "exporter"]
        let expected: [(String, String, [String: NectoJSONValue])] = [
            ("necto.plugin.opened", desktop.id, ["pluginSource": "desktop"]),
            ("necto.plugin.opened", device.id, ["pluginSource": "device"]),
            ("necto.plugin.installed", desktop.id, pluginParams),
            ("necto.plugin.removed", desktop.id, pluginParams),
            ("necto.plugin.installed", exporter.id, exporterParams),
            ("necto.plugin.removed", exporter.id, exporterParams),
            ("necto.plugin.enabled", desktop.id, [:]),
            ("necto.plugin.disabled", desktop.id, [:]),
        ]
        for (name, id, params) in expected {
            let event = try #require(events.first {
                $0.input.eventName == name && $0.source == .necto(relatedPluginID: id)
            })
            expectNativeEnvelope(event, relatedPluginID: id)
            #expect(event.input.params == params)
        }

        // Replay the recorded sources through policy so every asynchronous call is accounted for.
        await fixture.dispatcher.updatePolicy(.init(excludedPluginIDs: [desktop.id, device.id, exporter.id]))
        for event in events {
            #expect(await fixture.dispatcher.record(event.input, source: event.source) == false)
        }
        #expect(fixture.receiver.events == events)
    }

    @Test("Startup is handed off once across concurrent registration callbacks and replacement")
    func recordsStartupOnce() async throws {
        let fixture = Fixture()
        let logger = fixture.makeLogger()
        let firstID = try await fixture.dispatcher.registerExporter(receive: fixture.receiver.accept)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await logger.appStartedIfNeeded(registrationID: firstID) }
            }
        }
        let events = fixture.receiver.events
        #expect(events.count == 1)
        let event = try #require(events.first)
        expectNativeEnvelope(event)
        #expect(event.input.eventName == "necto.started")
        #expect(event.input.params.isEmpty)

        await fixture.dispatcher.unregisterExporter(registrationID: firstID)
        let replacement = Receiver()
        let replacementID = try await fixture.dispatcher.registerExporter(receive: replacement.accept)
        await logger.appStartedIfNeeded(registrationID: replacementID)
        #expect(replacement.events.isEmpty)
    }

    @Test("A missing or stale registration leaves startup available to the current exporter")
    func retriesStartupAfterRejectedAttempt() async throws {
        let fixture = Fixture()
        let logger = fixture.makeLogger()
        let staleID = try await fixture.dispatcher.registerExporter(receive: fixture.receiver.accept)
        await fixture.dispatcher.unregisterExporter(registrationID: staleID)
        await logger.appStartedIfNeeded(registrationID: staleID)
        #expect(fixture.receiver.events.isEmpty)

        let replacement = Receiver()
        let replacementID = try await fixture.dispatcher.registerExporter(receive: replacement.accept)
        await logger.appStartedIfNeeded(registrationID: staleID)
        #expect(replacement.events.isEmpty)

        await logger.appStartedIfNeeded(registrationID: replacementID)
        #expect(replacement.events.map(\.input.eventName) == ["necto.started"])
    }
}
