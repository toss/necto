//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

/// Installed and enabled in one place, because the answer to "is this plugin the
/// problem" is a switch and not a reinstall.
struct PluginTable: View {
    let model: NectoAppModel
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("On").frame(width: 34, alignment: .leading)
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Version").frame(width: 66, alignment: .leading)
                Text("Source").frame(width: 96, alignment: .leading)
                Spacer().frame(width: 80)
            }
            .font(.necto(.caption, scale: scale))
            .foregroundStyle(NectoTheme.textTertiary)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NectoTheme.border).frame(height: 1)
            }

            ForEach(model.plugins) { plugin in
                PluginRow(plugin: plugin, model: model, scale: scale)
            }

            if model.plugins.isEmpty {
                Text("Nothing installed yet.")
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                    .padding(.vertical, 12)
            }
        }
    }
}

private struct PluginRow: View {
    let plugin: NectoInstalledPlugin
    let model: NectoAppModel
    let scale: CGFloat

    private var isEnabled: Bool { !model.disabledIDs.contains(plugin.id) }

    var body: some View {
        HStack(spacing: 8) {
            NectoSwitch(isOn: isEnabled) { model.setPlugin(plugin.id, enabled: $0) }
                .frame(width: 34, alignment: .leading)
                .accessibilityLabel(NectoL10n.format("Enable %@", plugin.manifest.name))

            HStack(spacing: 6) {
                Image(systemName: plugin.manifest.icon.systemName)
                    .foregroundStyle(NectoTheme.textTertiary)
                Text(plugin.manifest.name)
                    .foregroundStyle(NectoTheme.text)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(plugin.manifest.version)
                .foregroundStyle(NectoTheme.textSecondary)
                .frame(width: 66, alignment: .leading)

            Text(plugin.manifest.author)
                .foregroundStyle(NectoTheme.textSecondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)

            // A built-in cannot be removed, so the row says so where the button would
            // be — at the same inset, or the column looks ragged.
            Group {
                if plugin.source == .installed {
                    Button(NectoL10n.text("Remove")) { model.remove(plugin) }
                        .buttonStyle(NectoButtonStyle(scale: scale, quiet: true, danger: true))
                } else {
                    Text("—")
                        .foregroundStyle(NectoTheme.textTertiary)
                        .padding(.horizontal, 10)
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .font(.necto(.label, scale: scale))
        .frame(height: NectoTheme.rowHeight * scale)
        .contextMenu {
            if plugin.source == .installed {
                Button(NectoL10n.text("Update from file…")) { model.beginInstallFromFile(updating: plugin) }
            }
        }
    }
}
