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
    @State private var selectedShellCaller: NectoShellCaller?

    private var scale: CGFloat {
        NectoTextSize.scale(forPoints: CGFloat(textPoints))
    }

    /// Font fields keep a stable typeface so an invalid preview value cannot hide the controls.
    private let appearanceFont = NectoFontPreference.defaultUI

    private var selectedLanguage: NectoLanguage {
        NectoLanguage(rawValue: language) ?? .system
    }

    enum Page: Hashable {
        case general
        case shellAccess
        case plugins
        case diagnostics
    }

    @State private var entries: [NectoDiagnosticsLog.Entry] = []
    @State private var droppedLines = 0
    @State private var didCopy = false
    @State private var didCopyCommand = false

    var body: some View {
        HStack(spacing: 0) {
            NectoNav(
                items: [
                    (.general, NectoL10n.text("General"), "slider.horizontal.3"),
                    (.shellAccess, NectoL10n.text("Shell Access"), "terminal"),
                    (.plugins, NectoL10n.text("Desktop Plugins"), "square.grid.2x2"),
                    (.diagnostics, NectoL10n.text("Log"), "text.alignleft"),
                ],
                selection: page,
                scale: scale,
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
                    case .diagnostics: diagnostics
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .padding(.leading, 12)
        .background(NectoTheme.background)
        .task(id: page) {
            if page != .shellAccess { selectedShellCaller = nil }
            if page == .plugins { await model.checkPluginUpdates() }
            guard page == .diagnostics else { return }
            entries = await model.diagnostics.recent()
            droppedLines = await model.diagnostics.dropped()
            // Opening the log is what marks it read, not fixing what it says.
            await model.acknowledgeIssues()
        }

    }



    // MARK: General

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
            hint: NectoL10n.text("Changes Necto's native interface. Plugins manage their own language."),
            scale: scale,
            fontFamily: appearanceFont
        ) {
            Picker(
                "",
                selection: Binding(
                    get: { selectedLanguage },
                    set: { language = $0.rawValue }
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
            hint: NectoL10n.text("Applies to the app and to every plugin. \u{2318}+ and \u{2318}- also move it."),
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
            hint: NectoL10n.text("A font family or CSS fallback stack."),
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
            hint: NectoL10n.text("Used for code, values and plugin data."),
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

        NectoRow(label: "Necto", hint: updateHint, scale: scale) {
            HStack(spacing: 8) {
                updateControl
                NectoRowValue(value: String(describing: NectoAppModel.nectoVersion), scale: scale)
            }
        }
        NectoRow(
            label: NectoL10n.text("Protocol"),
            hint: NectoL10n.text("The wire version this build speaks."),
            scale: scale
        ) {
            NectoRowValue(value: "1", scale: scale)
        }

        // The tool is in the app already. Linking it is the person's to run, not
        // Necto's to do for them: /usr/local/bin is not ours to write to, and a
        // password prompt for a convenience is a bad trade.
        if let command = Self.commandLineToolLink {
            NectoRow(
                label: NectoL10n.text("Command line tool"),
                hint: NectoL10n.text("Run this once to call Necto, and package plugins, from a terminal."),
                scale: scale
            ) {
                Button(didCopyCommand ? NectoL10n.text("Copied") : NectoL10n.text("Copy command")) {
                    copyCommandLineToolLink(command)
                }
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
            }
        }
    }

    /// Nil for a build that carries no tool — a debug run from Xcode, where the
    /// person can build it themselves and the row would only mislead.
    ///
    /// `/usr/local/bin` is owned by root and on a clean Apple Silicon Mac does not
    /// exist yet, so the command says `sudo` and makes the directory. Handing over a
    /// line that fails without explaining why is worse than asking for a password the
    /// person types themselves.
    private static var commandLineToolLink: String? {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/MacOS/necto-cli")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(tool.path)\" /usr/local/bin/necto && sudo ln -sf \"\(tool.path)\" /usr/local/bin/necto-cli"
    }

    private func copyCommandLineToolLink(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        didCopyCommand = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            didCopyCommand = false
        }
    }

    private var updateHint: String {
        switch model.updater.phase {
        case .idle: ""
        case .checking: NectoL10n.text("Checking for updates…")
        case .upToDate: NectoL10n.text("Up to date.")
        case let .available(version):
            NectoL10n.format("%@ is out — one click installs and relaunches.", String(describing: version))
        case let .outside(version):
            NectoL10n.format("%@ is out, but Necto is not running from /Applications.", String(describing: version))
        case let .working(step): step
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
        case .checking, .working:
            EmptyView()
        }
    }

    // MARK: Log

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

    // MARK: Plugins

    @ViewBuilder
    private var plugins: some View {
        NectoSectionTitle(NectoL10n.text("Installed"), scale: scale, isFirst: true)

        PluginTable(model: model, scale: scale)



        NectoSectionTitle(NectoL10n.text("Add and edit"), scale: scale)

        NectoRow(
            label: NectoL10n.text("Install from GitHub"),
            hint: NectoL10n.text("A repository's latest release, or one release of it."),
            scale: scale
        ) {
            Button(NectoL10n.text("Add…")) { model.beginAddingLink() }
                .buttonStyle(NectoButtonStyle(scale: scale))
        }

        NectoRow(
            label: NectoL10n.text("Install from a file"),
            hint: NectoL10n.text(
                "A folder or zip of a built desktop plugin. Nothing checks where a file came from, and it has no update to follow. Device plugins are not installed here — they ride in the app's own Swift package."
            ),
            scale: scale
        ) {
            Button(NectoL10n.text("Choose…")) { model.beginInstallFromFile() }
                .buttonStyle(NectoButtonStyle(scale: scale))
        }

        NectoRow(
            label: NectoL10n.text("Plugins folder"),
            hint: NectoL10n.text("New or changed folders need review after Reload. Deleting a folder removes its permissions."),
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
                "Plugins installed from a repository are checked when this page opens. Only releases that publish a manifest beside the archive can be checked without downloading them."
            ),
            scale: scale
        ) {
            Button(model.isCheckingUpdates ? NectoL10n.text("Checking…") : NectoL10n.text("Check again")) {
                Task { await model.checkPluginUpdates(quietly: false) }
            }
            .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
            .disabled(model.isCheckingUpdates)
        }

        if !model.pluginUpdates.isEmpty {
            NectoSectionTitle(NectoL10n.text("Newer releases"), scale: scale)
            ForEach(model.pluginUpdates.sorted(by: { $0.value.name < $1.value.name }), id: \.key) { id, update in
                NectoRow(
                    label: update.name,
                    hint: NectoL10n.format(
                        "%@ is published at %@. Installing it asks again, because a new version can bind to something the last one did not.",
                        String(describing: update.version),
                        update.repository.label
                    ),
                    scale: scale
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

        if !model.pluginsAwaitingApproval.isEmpty {
            NectoSectionTitle(NectoL10n.text("Review required"), scale: scale)
            ForEach(model.pluginsAwaitingApproval) { plugin in
                NectoRow(
                    label: plugin.manifest.name,
                    hint: NectoL10n.text("These files are new or have changed. They will not run until you approve their source."),
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
