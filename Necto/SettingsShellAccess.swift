//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoMacService
import SwiftUI

struct SettingsShellAccess: View {
    @Bindable var model: NectoAppModel
    let scale: CGFloat
    @Binding var selectedCaller: NectoShellCaller?
    @State private var isConfirmingFullAccess = false

    var body: some View {
        if let caller = selectedCaller {
            detail(caller)
        } else {
            overview
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            NectoSectionTitle(
                NectoL10n.text("Global override"),
                scale: scale,
                isFirst: true
            )
            NectoRow(
                label: NectoL10n.text("Full Access"),
                hint: NectoL10n.text(
                    "Allow every plugin and CLI request without confirmation."
                ),
                scale: scale
            ) {
                NectoSwitch(isOn: model.shellAccess.isFullAccessEnabled) { enabled in
                    if enabled {
                        isConfirmingFullAccess = true
                    } else {
                        Task { await model.shellAccess.setFullAccessEnabled(false) }
                    }
                }
            }

            if model.shellAccess.isFullAccessEnabled {
                NectoNotice(
                    title: NectoL10n.text("Plugin-level settings are ignored"),
                    detail: NectoL10n.text("Turning Full Access off restores every saved plugin setting."),
                    isDanger: true,
                    scale: scale
                )
                .padding(.top, 8)
            }

            NectoSectionTitle(NectoL10n.text("Plugin access"), scale: scale)
            Text(NectoL10n.text("Select a plugin to review or change its shell permissions."))
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(NectoTheme.textTertiary)
                .padding(.bottom, 8)

            callerGroup(NectoL10n.text("Device Plugins"), callers: callers(of: .device))
            callerGroup(NectoL10n.text("Desktop Plugins"), callers: callers(of: .desktop))
            callerGroup(NectoL10n.text("CLI access"), callers: callers(of: .cli))

            Text(NectoL10n.text("Plugins without the shell bridge do not appear here."))
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(NectoTheme.textTertiary)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isConfirmingFullAccess) {
            NectoDialog(
                title: NectoL10n.text("Enable Full Access?"),
                caption: NectoL10n.text("Every plugin and necto-cli command will run without confirmation."),
                scale: scale
            ) {
                NectoNotice(
                    title: NectoL10n.text("No plugin-level protection"),
                    detail: NectoL10n.text("This mode gives every caller the same shell access as a local native app."),
                    isDanger: true,
                    scale: scale
                )
            } actions: {
                Button(NectoL10n.text("Cancel")) { isConfirmingFullAccess = false }
                    .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                    .keyboardShortcut(.cancelAction)
                Button(NectoL10n.text("Enable")) {
                    isConfirmingFullAccess = false
                    Task { await model.shellAccess.setFullAccessEnabled(true) }
                }
                .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func callers(of kind: NectoShellCaller.Kind) -> [NectoShellCaller] {
        model.shellCallers.filter { $0.kind == kind }
    }

    @ViewBuilder
    private func callerGroup(_ title: String, callers: [NectoShellCaller]) -> some View {
        if !callers.isEmpty {
            Text(title)
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(NectoTheme.textTertiary)
                .padding(.top, 12)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(callers) { caller in
                    shellCallerRow(caller)
                }
            }
        }
    }

    private func shellCallerRow(_ caller: NectoShellCaller) -> some View {
        Button { selectedCaller = caller } label: {
            HStack(spacing: 10) {
                Image(systemName: caller.systemImage)
                    .foregroundStyle(NectoTheme.textTertiary)
                    .frame(width: 18)
                Text(caller.name)
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.text)
                Spacer(minLength: 12)
                Text(accessDescription(for: caller.principal))
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9 * scale, weight: .medium))
                    .foregroundStyle(NectoTheme.textTertiary)
            }
            .frame(minHeight: 42 * scale)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle().fill(NectoTheme.border).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func accessDescription(for principal: NectoPluginPrincipal) -> String {
        let grant = model.shellAccess.grant(for: principal)
        switch grant.level {
        case .protected:
            return NectoL10n.text("Protected")
        case .commandApproval:
            let count = grant.approvedCommands.count
            let key = count == 1
                ? "Command approval · %ld command"
                : "Command approval · %ld commands"
            return NectoL10n.format(key, count)
        case .fullAccess:
            return NectoL10n.text("Full access")
        }
    }

    private func detail(_ caller: NectoShellCaller) -> some View {
        ShellCallerDetail(
            controller: model.shellAccess,
            caller: caller,
            scale: scale,
            back: { selectedCaller = nil }
        )
    }
}

private struct ShellCallerDetail: View {
    @Bindable var controller: NectoShellAccessController
    let caller: NectoShellCaller
    let scale: CGFloat
    let back: () -> Void
    @State private var isAddingCommand = false

    private var grant: NectoShellGrant { controller.grant(for: caller.principal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                Label(NectoL10n.text("Shell access"), systemImage: "chevron.left")
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)

            Text(caller.name)
                .font(.necto(.title, scale: scale))
                .foregroundStyle(NectoTheme.text)
            Text(metadata)
                .font(.necto(.body, scale: scale))
                .foregroundStyle(NectoTheme.textSecondary)
                .padding(.top, 2)

            NectoSectionTitle(NectoL10n.text("Access for this plugin"), scale: scale)
            VStack(spacing: 0) {
                accessRow(
                    .protected,
                    title: NectoL10n.text("Protected"),
                    detail: NectoL10n.text("Reject every shell request from this plugin.")
                )
                accessRow(
                    .commandApproval,
                    title: NectoL10n.text("Command approval"),
                    detail: NectoL10n.text("Run only the exact commands listed below.")
                )
                accessRow(
                    .fullAccess,
                    title: NectoL10n.text("Full access"),
                    detail: NectoL10n.text("Run any shell command from this plugin without confirmation.")
                )
            }

            if grant.level == .fullAccess {
                NectoNotice(
                    title: NectoL10n.text("Full access"),
                    detail: NectoL10n.text("This plugin has the same shell access as a local native app."),
                    isDanger: true,
                    scale: scale
                )
                .padding(.top, 8)
            }

            if grant.level == .commandApproval {
                approvedCommands
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isAddingCommand) {
            AddShellCommandSheet(
                pluginName: caller.name,
                scale: scale,
                cancel: { isAddingCommand = false },
                add: { command in
                    isAddingCommand = false
                    Task { try? await controller.approve(command, for: caller.principal) }
                }
            )
        }
    }

    private var metadata: String {
        [caller.version, caller.author.map { NectoL10n.format("by %@", $0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func accessRow(
        _ level: NectoShellAccessLevel,
        title: String,
        detail: String
    ) -> some View {
        Button {
            Task { await controller.setAccessLevel(level, for: caller.principal) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: grant.level == level ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(grant.level == level ? NectoTheme.text : NectoTheme.textTertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.necto(.body, scale: scale))
                        .foregroundStyle(NectoTheme.text)
                    Text(detail)
                        .font(.necto(.label, scale: scale))
                        .foregroundStyle(NectoTheme.textSecondary)
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
    }

    private var approvedCommands: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                NectoSectionTitle(NectoL10n.text("Approved commands"), scale: scale)
                Spacer(minLength: 12)
                Button(NectoL10n.text("Add command…")) { isAddingCommand = true }
                    .buttonStyle(NectoButtonStyle(scale: scale))
                    .padding(.top, 16)
            }

            if grant.approvedCommands.isEmpty {
                NectoEmpty(
                    title: NectoL10n.text("No approved commands"),
                    detail: NectoL10n.text("Add one here or approve a request from the plugin."),
                    scale: scale
                )
                .frame(height: 100)
            } else {
                VStack(spacing: 0) {
                    ForEach(grant.approvedCommands.sorted(), id: \.self) { command in
                        HStack(spacing: 12) {
                            Text(command)
                                .font(.necto(.label, scale: scale, mono: true))
                                .foregroundStyle(NectoTheme.text)
                                .textSelection(.enabled)
                            Spacer(minLength: 12)
                            Button(NectoL10n.text("Remove")) {
                                Task { await controller.revoke(command, for: caller.principal) }
                            }
                            .buttonStyle(NectoButtonStyle(scale: scale, quiet: true, danger: true))
                        }
                        .frame(minHeight: 42 * scale)
                        .overlay(alignment: .top) {
                            Rectangle().fill(NectoTheme.border).frame(height: 1)
                        }
                    }
                }

                Button(NectoL10n.text("Remove all commands")) {
                    Task { await controller.revokeAll(for: caller.principal) }
                }
                .buttonStyle(NectoButtonStyle(scale: scale, danger: true))
                .padding(.top, 12)
            }
        }
    }
}

private struct AddShellCommandSheet: View {
    let pluginName: String
    let scale: CGFloat
    let cancel: () -> Void
    let add: (String) -> Void
    @State private var command = ""

    var body: some View {
        NectoDialog(
            title: NectoL10n.text("Add an approved command"),
            caption: NectoL10n.format("%@ may run this exact command without asking again.", pluginName),
            scale: scale
        ) {
            NectoField(
                placeholder: "/usr/bin/git status --short",
                text: $command,
                scale: scale,
                fontFamily: NectoFontPreference.value(
                    for: NectoFontPreference.codeKey,
                    fallback: NectoFontPreference.defaultCode
                )
            )
        } actions: {
            Button(NectoL10n.text("Cancel"), action: cancel)
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                .keyboardShortcut(.cancelAction)
            Button(NectoL10n.text("Add")) { add(command) }
                .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
