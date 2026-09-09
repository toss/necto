//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoMacService
import Foundation
import SwiftUI

struct ShellApprovalSheet: View {
    let pending: NectoShellAccessController.PendingApproval
    let pluginName: String
    let pluginSource: String
    let scale: CGFloat
    let deny: () -> Void
    let approve: () -> Void

    var body: some View {
        NectoDialog(
            title: NectoL10n.text("Allow shell access?"),
            caption: pluginName,
            scale: scale
        ) {
            VStack(alignment: .leading, spacing: 12) {
                NectoPairs(rows: [
                    (NectoL10n.text("Plugin ID"), pending.request.principal.pluginID),
                    (NectoL10n.text("Source"), pluginSource),
                ], scale: scale)
                .fixedSize(horizontal: false, vertical: true)

                if pending.request.access == .fullAccess {
                    NectoNotice(
                        title: NectoL10n.text("Full access for this plugin"),
                        detail: NectoL10n.text("This plugin will be able to run any shell command without asking again."),
                        isDanger: true,
                        scale: scale
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(pending.request.commands, id: \.self) { command in
                            Text(command)
                                .font(.necto(.label, scale: scale, mono: true))
                                .foregroundStyle(NectoTheme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .overlay(alignment: .top) {
                                    Rectangle().fill(NectoTheme.border).frame(height: 1)
                                }
                        }
                    }

                    Text(NectoL10n.text("Approving adds these exact commands to this plugin's Command approval list."))
                        .font(.necto(.caption, scale: scale))
                        .foregroundStyle(NectoTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !pluginMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NectoL10n.text("Plugin-provided message"))
                            .font(.necto(.caption, scale: scale))
                            .foregroundStyle(NectoTheme.textTertiary)
                        Text(pluginMessage)
                            .font(.necto(.label, scale: scale))
                            .foregroundStyle(NectoTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } actions: {
            Button(NectoL10n.text("Deny"), action: deny)
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                .keyboardShortcut(.cancelAction)
            Button(NectoL10n.text("Approve"), action: approve)
                .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var pluginMessage: String {
        [pending.request.title, pending.request.message]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
