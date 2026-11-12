//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel

/// Names and builds the native shell's usage events. Plugin event schemas remain
/// plugin-owned; common metadata, collection policy and delivery stay in the dispatcher.
@MainActor
final class NectoUsageLogger {
    enum SettingsPage: String {
        case general
        case shellAccess
        case plugins
        case eventExporter
        case diagnostics
    }

    private let eventDispatcher: NectoEventDispatcher
    private let diagnostics: NectoDiagnosticsLog
    private let cliInstaller: NectoCLIInstaller
    private let agentSkills: NectoAgentSkills
    private var didRecordAppStarted = false
    private var appStartRecording: Task<Void, Never>?

    init(
        eventDispatcher: NectoEventDispatcher,
        diagnostics: NectoDiagnosticsLog,
        cliInstaller: NectoCLIInstaller,
        agentSkills: NectoAgentSkills
    ) {
        self.eventDispatcher = eventDispatcher
        self.diagnostics = diagnostics
        self.cliInstaller = cliInstaller
        self.agentSkills = agentSkills
    }

    /// A replacement waits for the prior attempt before deciding whether startup
    /// was handed off. A stale registration must not consume the once-per-run event.
    func appStartedIfNeeded(registrationID: UUID) async {
        let previous = appStartRecording
        let recording = Task {
            await previous?.value
            guard !didRecordAppStarted else { return }
            do {
                didRecordAppStarted = await eventDispatcher.record(
                    try NectoEvent.Input(eventName: "necto.started"),
                    source: .necto(),
                    expectedExporterRegistrationID: registrationID
                )
            } catch {
                await diagnostics.append(.failure, .exporter, "Could not record a Necto usage event")
            }
        }
        appStartRecording = recording
        await recording.value
    }

    func settingsOpened(page: SettingsPage) {
        cliInstaller.refresh()
        agentSkills.refresh()
        record("necto.settings.opened", params: [
            "page": .string(page.rawValue),
            "languagePreference": .string(NectoL10n.language.rawValue),
            "displayLanguage": .string(NectoL10n.languageCode),
            "cliInstalled": .bool(cliInstaller.isInstalled),
            "codexSkillInstalled": .bool(agentSkills.installed.contains(.codex)),
            "claudeSkillInstalled": .bool(agentSkills.installed.contains(.claude)),
        ])
    }

    func languageChanged(to language: NectoLanguage) {
        record("necto.setting.changed", params: [
            "setting": .string("language"),
            "value": .string(language.rawValue),
            "displayLanguage": .string(NectoL10n.languageCode),
        ])
    }

    func agentSkillInstallCompleted(
        agent: NectoAgentSkills.Agent,
        result: NectoAgentSkills.InstallResult
    ) {
        record("necto.agent_skill.install_completed", params: [
            "agent": .string(agent.rawValue),
            "action": .string(result.isUpdate ? "update" : "install"),
            "result": .string(result.succeeded ? "success" : "failure"),
        ])
    }

    func pluginOpened(_ plugin: NectoInstalledPlugin) {
        record(
            "necto.plugin.opened",
            params: ["pluginSource": .string(plugin.source == .installed ? "desktop" : "device")],
            relatedPluginID: plugin.id
        )
    }

    func pluginInstalled(_ package: NectoInstalledPackage) {
        record("necto.plugin.installed", params: packageParams(package), relatedPluginID: package.id)
    }

    func pluginRemoved(_ package: NectoInstalledPackage) {
        record("necto.plugin.removed", params: packageParams(package), relatedPluginID: package.id)
    }

    func pluginEnabledChanged(id: String, enabled: Bool) {
        record(enabled ? "necto.plugin.enabled" : "necto.plugin.disabled", relatedPluginID: id)
    }

    private func packageParams(_ package: NectoInstalledPackage) -> [String: NectoJSONValue] {
        [
            "pluginVersion": .string(package.manifest.version),
            "packageType": .string(package.manifest.type == .eventExporter ? "exporter" : "plugin"),
        ]
    }

    private func record(
        _ eventName: String,
        params: [String: NectoJSONValue] = [:],
        relatedPluginID: String? = nil
    ) {
        Task {
            do {
                let input = try NectoEvent.Input(eventName: eventName, params: params)
                await eventDispatcher.record(input, source: .necto(relatedPluginID: relatedPluginID))
            } catch {
                await diagnostics.append(.failure, .exporter, "Could not record a Necto usage event")
            }
        }
    }
}
