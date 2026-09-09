//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import SwiftUI

/// The one screen that has to be read rather than clicked through.
///
/// It lists every bridge the plugin binds to, in one list and in name order. There is no
/// read-or-write grouping: that would come from the manifest, and the manifest is
/// written by whoever wrote the plugin — which is the wrong source on this screen of all
/// screens. The names say it, and they are Necto's.
struct PluginApprovalSheet: View {
    let staged: NectoPluginInstaller.Staged
    let scale: CGFloat
    let cancel: () -> Void
    let approve: () -> Void

    private var manifest: NectoPluginManifest { staged.manifest }

    var body: some View {
        NectoDialog(
            title: NectoL10n.format(staged.replaces == nil ? "Install %@?" : "Update %@?", manifest.name),
            caption: NectoL10n.format(
                "%@ by %@ · web assets only, no native code",
                manifest.version,
                manifest.author
            ),
            scale: scale
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if let replaces = staged.replaces {
                    NectoNotice(
                        title: NectoL10n.format("Update %@", replaces),
                        detail: NectoL10n.text(
                            staged.keepsPermissions
                                ? "The ID matches, but Necto cannot verify the author of local files. Only update if you trust their source. This keeps existing permissions and settings, including Shell Access."
                                : "This folder has no installation identity yet. Confirm its source to register it as a new installation. Previous permissions are not inherited."
                        ),
                        isDanger: true,
                        scale: scale
                    )
                    .padding(.bottom, 8)
                }

                Text(manifest.id)
                    .font(.necto(.caption, scale: scale, mono: true))
                    .foregroundStyle(NectoTheme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.bottom, 8)

                Text(staged.origin)
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(bindings, id: \.identity) { binding in
                            GrantRow(binding: binding, scale: scale)
                        }

                        if manifest.operations.isEmpty {
                            Text("This plugin asks for nothing. It can draw, and that is all.")
                                .font(.necto(.label, scale: scale))
                                .foregroundStyle(NectoTheme.textSecondary)
                        }

                        Text("Installing is the agreement. An update that binds to something new asks again.")
                            .font(.necto(.caption, scale: scale))
                            .foregroundStyle(NectoTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        } actions: {
            Button(NectoL10n.text("Cancel"), action: cancel)
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                .keyboardShortcut(.cancelAction)

            Button(NectoL10n.text(staged.replaces == nil ? "Install" : "Update"), action: approve)
                .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
                .accessibilityIdentifier("plugin-install.confirm")
        }
    }

    private var bindings: [NectoBridgeBinding] {
        manifest.operations.map(\.binding).sorted { $0.name < $1.name }
    }
}

private struct GrantRow: View {
    let binding: NectoBridgeBinding
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Who answers it, which is the part of the name a reader skips over.
            Text(binding.type == .device ? NectoL10n.text("app") : "Necto")
                .font(.necto(.label, scale: scale))
                .foregroundStyle(NectoTheme.textTertiary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(binding.name)
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.text)
                    .textSelection(.enabled)

                Text(NectoBridgeWording.plain(for: binding.name))
                    .font(.necto(.caption, scale: scale, mono: false))
                    .foregroundStyle(NectoTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(NectoTheme.border).frame(height: 1)
        }
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
