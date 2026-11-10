//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoMacService
import NectoModel
import SwiftUI

/// Settings as a screen of the app, in the same panel a plugin gets.
///
/// Not a floating window: managing plugins is something you do *while* looking at what
/// they produce, and a sheet that has to be dismissed first gets in the way of that.
///
/// Two columns, because one flat list stopped working the moment plugins arrived —
/// how the app looks and which plugins are installed have nothing to do with each
/// other.
struct SettingsScreen: View {
    @Bindable var model: NectoAppModel
    @AppStorage(NectoTextSize.key) private var textPoints = Double(NectoTextSize.base)
    @AppStorage(NectoFontPreference.uiKey) private var uiFontFamily = NectoFontPreference.defaultUI
    @AppStorage(NectoFontPreference.codeKey) private var codeFontFamily = NectoFontPreference.defaultCode
    @AppStorage(NectoLanguage.key) private var language = NectoLanguage.system.rawValue
    @AppStorage("settingsNavWidth") private var navWidth = Double(NectoNav<Page>.defaultWidth)
    @State private var page = Page.general
    @State private var eventPluginSearch = ""
    @State private var selectedShellCaller: NectoShellCaller?

    private var scale: CGFloat {
        NectoTextSize.scale(forPoints: CGFloat(textPoints))
    }

    /// Font fields keep a stable typeface so an invalid preview value cannot hide the controls.
    private let appearanceFont = NectoFontPreference.defaultUI

    private var selectedLanguage: NectoLanguage {
        NectoLanguage(rawValue: language) ?? .system
    }

    typealias Page = NectoUsageLogger.SettingsPage

    @State private var entries: [NectoDiagnosticsLog.Entry] = []
    @State private var droppedLines = 0
    @State private var didCopy = false
    @State private var exporterEntries: [NectoDiagnosticsLog.Entry] = []
    @State private var didCopyExporterLog = false

    var body: some View {
        HStack(spacing: 0) {
            NectoNav(
                items: [
                    (.general, NectoL10n.text("General"), "slider.horizontal.3"),
                    (.shellAccess, NectoL10n.text("Shell Access"), "terminal"),
                    (.plugins, NectoL10n.text("Desktop Plugins"), "square.grid.2x2"),
                    (.eventExporter, NectoL10n.text("Event Exporter"), "arrow.up.doc"),
                    (.diagnostics, NectoL10n.text("Log"), "text.alignleft"),
                ],
                selection: page,
                scale: scale,
                updates: Set([model.updater.hasUpdate ? Page.general : nil,
                              model.pluginUpdates.isEmpty ? nil : Page.plugins].compactMap { $0 }),
                width: Binding(
                    get: { CGFloat(navWidth) },
                    set: { navWidth = Double($0) }
                )
            ) { page = $0 }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch page {
                    case .general: general
                    case .shellAccess:
                        SettingsShellAccess(
                            model: model,
                            scale: scale,
                            selectedCaller: $selectedShellCaller
                        )
                    case .plugins: plugins
                    case .eventExporter: eventExporter
                    case .diagnostics: diagnostics
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .padding(.leading, 12)
        .background(NectoTheme.background)
        .onChange(of: page, initial: true) { _, page in
            model.usageLogger.settingsOpened(page: page)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if page == .general {
                model.cliInstaller.refresh()
                model.agentSkills.refresh()
            }
        }
        .task(id: page) {
            if page != .shellAccess { selectedShellCaller = nil }
            if page == .plugins { await model.checkPluginUpdates() }
            if page == .eventExporter {
                for await entries in await model.diagnostics.updates(source: .exporter) {
                    guard !Task.isCancelled else { return }
                    exporterEntries = entries
                }
                return
            }
            guard page == .diagnostics else { return }
            entries = await model.diagnostics.recent()
            droppedLines = await model.diagnostics.dropped()
            // Opening the log is what marks it read, not fixing what it says.
            await model.acknowledgeIssues()
        }

    }



    @ViewBuilder
    private var general: some View {
        NectoSectionTitle(
            NectoL10n.text("Appearance"),
            scale: scale,
            isFirst: true,
            fontFamily: appearanceFont
        )

        NectoRow(
            label: NectoL10n.text("Language"),
            hint: NectoL10n.text("Necto's display language. Plugins use their own language settings."),
            scale: scale,
            fontFamily: appearanceFont
        ) {
            Picker(
                "",
                selection: Binding(
                    get: { selectedLanguage },
                    set: { newLanguage in
                        guard newLanguage != NectoL10n.language else { return }
                        language = newLanguage.rawValue
                        model.usageLogger.languageChanged(to: newLanguage)
                    }
                )
            ) {
                ForEach(NectoLanguage.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.necto(.body, scale: scale, family: appearanceFont))
            .frame(width: 190)
            .id(language)
        }

        NectoRow(
            label: NectoL10n.text("Text size"),
            hint: NectoL10n.text("Text size in the app and plugins. Shortcuts: \u{2318}+ and \u{2318}-."),
            scale: scale,
            fontFamily: appearanceFont
        ) {
            NectoStepper(
                value: CGFloat(textPoints),
                range: NectoTextSize.range,
                step: NectoTextSize.step,
                unit: "pt",
                scale: scale,
                fontFamily: appearanceFont
            ) { textPoints = Double(NectoTextSize.clamp($0)) }
        }

        NectoRow(
            label: NectoL10n.text("UI font"),
            hint: NectoL10n.text("Font for the app and plugin interface."),
            scale: scale,
            fontFamily: appearanceFont
        ) {
            NectoField(
                placeholder: NectoFontPreference.defaultUI,
                text: $uiFontFamily,
                scale: scale,
                fontFamily: appearanceFont
            )
            .frame(width: 190)
        }

        NectoRow(
            label: NectoL10n.text("Code font"),
            hint: NectoL10n.text("Font for code, values and plugin data."),
            scale: scale,
            fontFamily: appearanceFont
        ) {
            NectoField(
                placeholder: NectoFontPreference.defaultCode,
                text: $codeFontFamily,
                scale: scale,
                fontFamily: appearanceFont
            )
            .frame(width: 190)
        }

        NectoSectionTitle(NectoL10n.text("About"), scale: scale)

        NectoRow(label: "Necto", hint: updateHint, scale: scale, hasUpdate: model.updater.hasUpdate) {
            HStack(spacing: 8) {
                updateControl
                NectoRowValue(value: String(describing: NectoAppModel.nectoVersion), scale: scale)
                    // The fixed-width progress view can otherwise collapse this text to zero width.
                    .fixedSize()
            }
        }
        NectoRow(
            label: NectoL10n.text("Protocol"),
            hint: NectoL10n.text("Version used to communicate with connected apps."),
            scale: scale
        ) {
            NectoRowValue(value: "1", scale: scale)
        }

        if model.cliInstaller.isAvailable {
            NectoRow(
                label: NectoL10n.text("Command line tool"),
                hint: NectoL10n.text(model.cliInstaller.isInstalled
                    ? "Use necto or necto-cli in your terminal."
                    : "Use necto or necto-cli in your terminal. Installation requires administrator approval."),
                scale: scale
            ) {
                Button(NectoL10n.text(model.cliInstaller.isInstalling ? "Installing…"
                    : model.cliInstaller.isInstalled ? "Installed" : "Install CLI")) {
                    Task { await model.cliInstaller.install() }
                }
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                .disabled(model.cliInstaller.isInstalling || model.cliInstaller.isInstalled)
                .accessibilityIdentifier("settings.cli.install")
            }
            if let error = model.cliInstaller.error {
                Text(error)
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.danger)
                    .textSelection(.enabled)
            }

            if !model.agentSkills.agents.isEmpty {
                NectoSectionTitle(NectoL10n.text("Agent skills"), scale: scale)
                ForEach(model.agentSkills.agents) { agent in
                    NectoRow(
                        label: agent.name,
                        hint: NectoL10n.format("Use Necto from %@.", agent.name),
                        scale: scale
                    ) {
                        Button(NectoL10n.text(model.agentSkills.installing == agent ? "Installing…"
                            : model.agentSkills.updates.contains(agent) ? "Update"
                            : model.agentSkills.installed.contains(agent) ? "Installed" : "Add")) {
                            Task {
                                guard let result = await model.agentSkills.install(agent) else { return }
                                model.usageLogger.agentSkillInstallCompleted(agent: agent, result: result)
                            }
                        }
                        .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                        .disabled(model.agentSkills.installing != nil
                            || (model.agentSkills.installed.contains(agent) && !model.agentSkills.updates.contains(agent)))
                        .accessibilityIdentifier("settings.skill.install.\(agent.rawValue)")
                    }
                }
                if let error = model.agentSkills.error {
                    Text(error)
                        .font(.necto(.label, scale: scale))
                        .foregroundStyle(NectoTheme.danger)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var updateHint: String {
        switch model.updater.phase {
        case .idle: ""
        case .checking: NectoL10n.text("Checking for updates…")
        case .upToDate: NectoL10n.text("Up to date.")
        case let .available(version):
            NectoL10n.format("Version %@ is available. Necto restarts after updating.", String(describing: version))
        case let .outside(version):
            NectoL10n.format("Version %@ is available. Move Necto to Applications to update.", String(describing: version))
        case .working: ""
        case let .failed(reason): reason
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch model.updater.phase {
        case .available:
            Button(NectoL10n.text("Update")) { Task { await model.updater.update() } }
                .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
        case .outside:
            Button(NectoL10n.text("Show releases")) { model.updater.showReleases() }
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
        case .failed:
            Button(NectoL10n.text("Retry")) { Task { await model.updater.check() } }
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
        case .idle, .upToDate:
            Button(NectoL10n.text("Check for updates")) { Task { await model.updater.check() } }
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
        case let .working(step, progress):
            NectoUpdateProgress(step: step, fraction: progress, scale: scale)
                .padding(.horizontal, 8)
                .frame(width: NectoNav<Page>.defaultWidth)
        case .checking:
            EmptyView()
        }
    }

    /// Native rather than a plugin, unlike every other screen. The one screen that has
    /// to say why a plugin would not load cannot be a plugin.
    @ViewBuilder
    private var diagnostics: some View {
        HStack(alignment: .firstTextBaseline) {
            NectoSectionTitle(NectoL10n.text("What Necto did"), scale: scale, isFirst: true)
            Spacer(minLength: 12)

            // Selecting several hundred lines by hand is not a thing anyone should have
            // to do to paste a log into a bug report.
            Button(didCopy ? NectoL10n.text("Copied") : NectoL10n.text("Copy all")) { copyLog() }
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                .disabled(entries.isEmpty)
        }

        if entries.isEmpty {
            NectoEmpty(
                title: NectoL10n.text("Nothing logged yet"),
                detail: NectoL10n.text("Connections, plugins and refused calls appear here."),
                scale: scale
            )
            .frame(height: 120)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    LogRow(entry: entry, scale: scale)
                }
            }

            if droppedLines > 0 {
                Text(NectoL10n.format("%ld earlier lines dropped.", droppedLines))
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                    .padding(.top, 8)
            }
        }
    }

    private func copyLog() {
        Task {
            let transcript = await model.diagnostics.transcript()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)

            didCopy = true
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
        }
    }

    @ViewBuilder
    private var eventExporter: some View {
        NectoSectionTitle(NectoL10n.text("Event Exporter"), scale: scale, isFirst: true)

        if let exporter = model.eventExporter {
            NectoRow(
                label: exporter.manifest.name,
                hint: [exporter.id, exporter.manifest.version, exporter.installation?.origin?.label ?? exporter.rootURL.path].joined(separator: " · "),
                scale: scale
            ) {
                Button(NectoL10n.text("Remove")) { model.remove(exporter.package) }
                    .buttonStyle(NectoButtonStyle(scale: scale, quiet: true, danger: true))
            }
            .contextMenu {
                Button(NectoL10n.text("Update from file…")) {
                    model.beginInstallFromFile(updating: exporter.package)
                }
            }
            Text(NectoL10n.text("Includes Necto activity and current and future plugins, except excluded IDs. Remove the exporter to stop collection."))
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(NectoTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
        } else {
            Text(NectoL10n.text("No event exporter installed. Install one to allow collection. Plugin exclusions are preserved."))
                .font(.necto(.label, scale: scale))
                .foregroundStyle(NectoTheme.textSecondary)
                .padding(.vertical, 8)
        }

        NectoSectionTitle(NectoL10n.text("Plugin events"), scale: scale)

        if !model.eventCollectionPlugins.isEmpty {
            NectoField(placeholder: NectoL10n.text("Search plugin IDs"), text: $eventPluginSearch, scale: scale)
                .accessibilityIdentifier("settings.event-collection.search")
                .padding(.vertical, 8)

            ForEach(model.eventCollectionPlugins.filter {
                eventPluginSearch.isEmpty || $0.id.localizedStandardContains(eventPluginSearch)
                    || $0.name.localizedStandardContains(eventPluginSearch)
            }) { plugin in
                NectoRow(label: plugin.name, hint: "\(plugin.id) · \(plugin.detail)", scale: scale) {
                    NectoSwitch(isOn: !model.eventCollectionPolicy.excludedPluginIDs.contains(plugin.id)) { included in
                        Task { await model.setEventCollection(plugin.id, included: included) }
                    }
                    .accessibilityLabel(NectoL10n.format("Include %@ in event collection", plugin.id))
                    .accessibilityIdentifier("settings.event-collection.\(plugin.id)")
                }
            }
            Text(NectoL10n.text("Excluding a plugin stops new events from all apps and versions using its ID. Events already shared with the exporter may still be sent."))
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(NectoTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }

        exporterDiagnostics
    }

    @ViewBuilder
    private var exporterDiagnostics: some View {
        HStack(alignment: .firstTextBaseline) {
            NectoSectionTitle(NectoL10n.text("Exporter diagnostics"), scale: scale)
            Spacer(minLength: 12)
            Button(didCopyExporterLog ? NectoL10n.text("Copied") : NectoL10n.text("Copy all")) {
                copyExporterLog()
            }
            .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
            .disabled(exporterEntries.isEmpty)
        }

        if exporterEntries.isEmpty {
            NectoEmpty(
                title: NectoL10n.text("Nothing logged yet"),
                detail: NectoL10n.text("Exporter diagnostics appear here."),
                scale: scale
            )
            .frame(height: 120)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(exporterEntries) { entry in
                    LogRow(entry: entry, scale: scale)
                }
            }
        }
    }

    private func copyExporterLog() {
        Task {
            let transcript = await model.diagnostics.transcript(source: .exporter)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)

            didCopyExporterLog = true
            try? await Task.sleep(for: .seconds(1.4))
            didCopyExporterLog = false
        }
    }

    @ViewBuilder
    private var plugins: some View {
        NectoSectionTitle(NectoL10n.text("Installed plugins"), scale: scale, isFirst: true)

        PluginTable(model: model, scale: scale)


        NectoSectionTitle(NectoL10n.text("Install and manage"), scale: scale)

        NectoRow(
            label: NectoL10n.text("Install from GitHub"),
            hint: NectoL10n.text("Install using a repository or release URL."),
            scale: scale
        ) {
            Button(NectoL10n.text("Add…")) { model.beginAddingLink() }
                .buttonStyle(NectoButtonStyle(scale: scale))
        }

        NectoRow(
            label: NectoL10n.text("Install from a file"),
            hint: NectoL10n.text(
                "Install from a folder or ZIP file. Source verification and update checks are not available."
            ),
            scale: scale
        ) {
            Button(NectoL10n.text("Choose…")) { model.beginInstallFromFile() }
                .buttonStyle(NectoButtonStyle(scale: scale))
        }

        NectoRow(
            label: NectoL10n.text("Plugins folder"),
            hint: NectoL10n.text("Reload after adding or changing a plugin folder."),
            scale: scale
        ) {
            HStack(spacing: 8) {
                Button(NectoL10n.text("Open")) { NectoPluginLibrary.reveal() }
                    .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                Button(NectoL10n.text("Reload")) { Task { await model.reloadPlugins() } }
                    .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                    .disabled(model.isInstalling)
            }
        }

        NectoRow(
            label: NectoL10n.text("Updates"),
            hint: NectoL10n.text(
                "Check for updates to plugins installed from GitHub."
            ),
            scale: scale
        ) {
            Button(model.isCheckingUpdates ? NectoL10n.text("Checking…") : NectoL10n.text("Check for updates")) {
                Task { await model.checkPluginUpdates(quietly: false) }
            }
            .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
            .disabled(model.isCheckingUpdates)
        }

        if !model.pluginUpdates.isEmpty {
            NectoSectionTitle(NectoL10n.text("Available updates"), scale: scale)
            ForEach(model.pluginUpdates.sorted(by: { $0.value.name < $1.value.name }), id: \.key) { id, update in
                NectoRow(
                    label: update.name,
                    hint: NectoL10n.format(
                        "Version %@ is available.",
                        String(describing: update.version)
                    ),
                    scale: scale,
                    hasUpdate: true
                ) {
                    Button(NectoL10n.text("Update")) { model.installUpdate(for: id) }
                        .buttonStyle(NectoButtonStyle(scale: scale))
                        .disabled(model.isInstalling)
                }
            }
        }

        if let failure = model.installFailure {
            NectoNotice(
                title: NectoL10n.text("Could not install"),
                detail: failure,
                isDanger: true,
                scale: scale
            )
                .padding(.top, 12)
        }

        if !model.packagesAwaitingApproval.isEmpty {
            NectoSectionTitle(NectoL10n.text("Review required"), scale: scale)
            ForEach(model.packagesAwaitingApproval) { plugin in
                NectoRow(
                    label: plugin.manifest.name,
                    hint: NectoL10n.text("Review the source before running new or changed files."),
                    scale: scale
                ) {
                    HStack(spacing: 8) {
                        Button(NectoL10n.text("Review")) { model.review(plugin) }
                            .buttonStyle(NectoButtonStyle(scale: scale))
                            .accessibilityIdentifier("plugin-install.review.\(plugin.id)")
                        Button(NectoL10n.text("Remove")) { model.remove(plugin) }
                            .buttonStyle(NectoButtonStyle(scale: scale, quiet: true, danger: true))
                    }
                }
            }
        }

        if !model.pluginFailures.isEmpty {
            NectoSectionTitle(NectoL10n.text("Not loaded"), scale: scale)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.pluginFailures.sorted(by: { $0.key < $1.key }), id: \.key) { name, reason in
                    NectoNotice(title: name, detail: reason, isDanger: true, scale: scale)
                }
            }
        }
    }
}
