//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoMacService
import NectoModel
import SwiftUI

/// Lists the requested bridges in name order with Necto's explanation of each bridge.
/// Exporter shell declarations are labeled separately as information from the author.
struct PluginApprovalSheet: View {
    let staged: NectoPluginInstaller.Staged
    let shellReview: NectoShellPolicy.Review?
    let scale: CGFloat
    let cancel: () -> Void
    let reject: () -> Void
    let approve: (NectoShellAccessLevel?) -> Void

    @State private var selectedAccessLevel: NectoShellAccessLevel?

    private var manifest: NectoPluginManifest { staged.manifest }
    private var isExporter: Bool { manifest.type == .eventExporter }

    private var canApprove: Bool {
        guard let shellReview, shellReview.requiresAccessChoice else { return true }
        guard let selectedAccessLevel else { return false }
        return shellReview.availableAccessLevels.contains(selectedAccessLevel)
    }

    var body: some View {
        NectoDialog(
            title: NectoL10n.format(staged.keepsPermissions ? "Update %@?" : "Install %@?", manifest.name),
            scale: scale
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(NectoL10n.format(
                        "%@ by %@ · web assets only, no native code",
                        manifest.version,
                        manifest.author
                    ))
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                    if staged.keepsPermissions, let replaces = staged.replaces {
                        NectoNotice(
                            title: NectoL10n.format("Update %@", replaces),
                            detail: updateDetail,
                            isDanger: true,
                            scale: scale
                        )
                        .padding(.bottom, 8)
                    }

                    if isExporter {
                        NectoNotice(
                            title: NectoL10n.text("Allow event collection"),
                            detail: NectoL10n.text("Necto activity and usage events from current and future plugins will be shared with this exporter. Existing plugin exclusions are preserved. You can exclude individual plugins at any time. Remove the exporter to stop all collection."),
                            scale: scale
                        )
                        .padding(.bottom, 8)

                        if let shellReview, shellReview.requestsShellAccess, shellReview.isFullAccessEnabled {
                            NectoNotice(
                                title: NectoL10n.text("Global Full Access is enabled"),
                                detail: NectoL10n.text("The global setting lets this exporter run any shell command. Registering it keeps its individual Shell Access settings."),
                                isDanger: true,
                                scale: scale
                            )
                            .padding(.bottom, 8)
                        }
                    }

                    if let shellReview, shellReview.requiresAccessChoice {
                        shellChoices(shellReview)
                            .padding(.bottom, 16)
                    }

                    ForEach(operations, id: \.id) { operation in
                        GrantRow(
                            binding: operation.binding,
                            scale: scale,
                            shellOperation: shellReview?.requestedOperations.first { $0.operationID == operation.id }
                        )
                    }

                    if manifest.operations.isEmpty && !isExporter {
                        Text("This plugin asks for nothing. It can draw, and that is all.")
                            .font(.necto(.label, scale: scale))
                            .foregroundStyle(NectoTheme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(NectoL10n.text(isExporter ? "Exporter ID" : "Plugin ID"))
                            .font(.necto(.label, scale: scale))
                            .foregroundStyle(NectoTheme.text)
                        Text(NectoL10n.text("Identifies this package across versions."))
                            .font(.necto(.caption, scale: scale))
                            .foregroundStyle(NectoTheme.textTertiary)
                        Text(manifest.id)
                            .font(.necto(.caption, scale: scale, mono: true))
                            .foregroundStyle(NectoTheme.textSecondary)
                            .textSelection(.enabled)

                        Text(NectoL10n.text("Installation source"))
                            .font(.necto(.label, scale: scale))
                            .foregroundStyle(NectoTheme.text)
                            .padding(.top, 8)
                        Text(staged.origin)
                            .font(.necto(.caption, scale: scale))
                            .foregroundStyle(NectoTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 16)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 400)
        } actions: {
            VStack(alignment: .trailing, spacing: 4) {
                Text(NectoL10n.text(canApprove
                    ? "Installing is the agreement. An update that binds to something new asks again."
                    : "Choose Shell Access to enable installation."))
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Spacer()
                    Button(NectoL10n.text(isExporter ? "Reject" : "Cancel"), action: isExporter ? reject : cancel)
                        .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))

                    Button(NectoL10n.text(isExporter
                        ? (staged.keepsPermissions ? "Update and allow collection" : "Install and allow collection")
                        : (staged.keepsPermissions ? "Update" : "Install"))) {
                        approve(shellReview?.requiresAccessChoice == true ? selectedAccessLevel : nil)
                    }
                    .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
                    .disabled(!canApprove)
                    .opacity(canApprove ? 1 : 0.45) // Matches --necto-disabled-opacity.
                    .accessibilityIdentifier("plugin-install.confirm")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onExitCommand(perform: cancel)
        .onChange(of: shellReview) { _, _ in
            selectedAccessLevel = nil
        }
    }

    private var updateDetail: String {
        if shellReview?.requiresAccessChoice == true {
            return NectoL10n.text("The ID matches, but Necto cannot verify the author of local files. Only update if you trust their source. The Shell Access option you choose replaces the saved one.")
        }
        return NectoL10n.text("The ID matches, but Necto cannot verify the author of local files. Only update if you trust their source. This keeps existing permissions and settings, including Shell Access.")
    }

    private var operations: [NectoOperation] {
        manifest.operations.sorted { $0.binding.name < $1.binding.name }
    }

    private func shellChoices(_ review: NectoShellPolicy.Review) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NectoSectionTitle(NectoL10n.text("Choose Shell Access"), scale: scale)
                .accessibilityAddTraits(.isHeader)

            ForEach(review.availableAccessLevels, id: \.self) { level in
                switch level {
                case .fullAccess:
                    accessRow(level, title: "Full access", detail: "Run any shell command without confirmation.")
                case .commandApproval:
                    accessRow(level, title: "Command approval", detail: "Run only the exact commands listed in the details below.")
                case .protected:
                    accessRow(level, title: "Protected", detail: "Block this exporter's shell requests.")
                }
            }

            if !review.canApproveDeclaredCommands {
                Text(NectoL10n.text("Command approval requires at least one shell execution operation, with a description and valid exact commands for each one."))
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func accessRow(_ level: NectoShellAccessLevel, title: String, detail: String) -> some View {
        let isSelected = selectedAccessLevel == level
        return Button {
            selectedAccessLevel = level
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? NectoTheme.text : NectoTheme.textTertiary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NectoL10n.text(title))
                        .font(.necto(.body, scale: scale))
                        .foregroundStyle(NectoTheme.text)
                    Text(NectoL10n.text(detail))
                        .font(.necto(.label, scale: scale))
                        .foregroundStyle(NectoTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle().fill(NectoTheme.border).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("plugin-install.shell-access.\(level.rawValue)")
    }
}

private struct GrantRow: View {
    let binding: NectoBridgeBinding
    let scale: CGFloat
    let shellOperation: NectoShellOperationInterpreter.Operation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if let title = shellTitle {
                    Text(title)
                        .font(.necto(.body, scale: scale).weight(.medium))
                        .foregroundStyle(NectoTheme.text)
                }

                Text(NectoBridgeWording.plain(for: binding.name))
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let shellOperation {
                ShellDeclaration(operation: shellOperation, scale: scale)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(NectoL10n.text("Capability identifier"))
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                Text(binding.name)
                    .font(.necto(.caption, scale: scale, mono: true))
                    .foregroundStyle(NectoTheme.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(NectoTheme.border).frame(height: 1)
        }
    }

    private var shellTitle: String? {
        switch binding.name {
        case "necto.desktop.shell.execute": NectoL10n.text("Run shell commands")
        case "necto.desktop.shell.authorization.request": NectoL10n.text("Request shell access")
        default: nil
        }
    }

}

private struct ShellDeclaration: View {
    let operation: NectoShellOperationInterpreter.Operation
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if operation.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detail("The author did not describe this operation.")
            } else {
                detail("Purpose · provided by the author")
                Text(verbatim: operation.description)
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            switch operation.interpretation {
            case let .execute(.values(commands)):
                if commands.isEmpty {
                    detail("The author did not declare exact commands.")
                } else {
                    detail("Requested commands")
                        .padding(.top, 8)
                    ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                        Text(verbatim: command)
                            .font(.necto(.label, scale: scale, mono: true))
                            .foregroundStyle(NectoTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if commands.contains(where: { (try? NectoShellPolicy.validated($0)) == nil }) {
                        detail("The declared list contains an invalid command.")
                    }
                }
            case .execute(.unavailable(.propertyNotDeclared)), .execute(.unavailable(.enumNotDeclared)):
                detail("The author did not declare exact commands.")
            case .execute(.unavailable):
                detail("Necto could not read exact commands from this declaration.")
            case .unsupportedContract:
                detail("This version of Necto does not recognize this shell operation's declaration.")
            case .authorizationRequest:
                EmptyView()
            }
        }
    }

    private func detail(_ key: String) -> some View {
        Text(NectoL10n.text(key))
            .font(.necto(.caption, scale: scale))
            .foregroundStyle(NectoTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a bridge means in a sentence, for the person deciding.
///
/// Written here rather than taken from the manifest: the description in a manifest is
/// written by whoever wrote the plugin, and this is the one screen where that is
/// exactly the wrong source. Anything Necto does not know says so.
enum NectoBridgeWording {
    static func plain(for name: String) -> String {
        switch name {
        case "necto.desktop.info": NectoL10n.text("Which version of Necto is running.")
        case "necto.desktop.ticks": NectoL10n.text("A repeating tick from Necto, for plugins that need one.")
        case "necto.desktop.storage.get", "necto.desktop.storage.keys":
            NectoL10n.text("Reads settings it stored itself, in a space only it can read.")
        case "necto.desktop.storage.set", "necto.desktop.storage.remove":
            NectoL10n.text("Stores its own settings, in a space only it can read.")
        case "necto.desktop.targets.list", "necto.desktop.targets.observe":
            NectoL10n.text("Which apps and devices are connected.")
        case "necto.desktop.files.save":
            NectoL10n.text("Saves files it produces into your Downloads folder. Never overwrites.")
        case "necto.desktop.files.reveal":
            NectoL10n.text("Opens Finder on a file it saved. Cannot point anywhere else.")
        case "necto.desktop.shell.execute":
            NectoL10n.text("Runs Bash commands on this Mac, subject to the Shell Access policy in Settings.")
        case "necto.desktop.shell.authorization.request":
            NectoL10n.text("Asks you to add exact Bash commands to this plugin's approved list.")
        case "necto.desktop.background.keepAlive":
            NectoL10n.text("Keeps running while other panels are visible. Disabling the plugin stops it.")
        case "necto.desktop.notifications.requestAuthorization", "necto.desktop.notifications.status", "necto.desktop.notifications.show":
            NectoL10n.text("Requests permission for and submits system notifications.")
        case "necto.device.network-records.list", "necto.device.network-records.detail",
             "necto.device.network-records.observe":
            NectoL10n.text("Every request the connected app makes, including headers and bodies.")
        case "necto.device.network-records.clear":
            NectoL10n.text("Empties the request log kept by the app.")
        case "necto.device.events.list", "necto.device.events.detail", "necto.device.events.observe":
            NectoL10n.text("Everything the connected app has logged.")
        case "necto.device.events.clear":
            NectoL10n.text("Empties the event log kept by the app.")
        case "necto.device.performance.metrics", "necto.device.performance.series",
             "necto.device.performance.observe":
            NectoL10n.text("What the connected app is spending: memory, frame rate, CPU.")
        default:
            NectoL10n.text("Not described by this version of Necto. Only install it if you trust the author.")
        }
    }
}
