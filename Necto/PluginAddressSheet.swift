//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

/// Where a plugin is coming from, asked for on its own screen.
///
/// This is a question with three good answers, and a settings row gives a field about a
/// fifth of the window and one line under it. The one people get wrong is leaving the
/// host off, which quietly means a different GitHub; the one nobody discovers is that a
/// release page can be pasted as it is. Neither fits in a placeholder, and both are
/// better shown than explained — every example here carries its host.
///
/// It stays open while the release is read, and stays open if that fails, because the
/// address is the thing being corrected and closing the screen takes it away.
struct PluginAddressSheet: View {
    let scale: CGFloat
    let isReading: Bool
    let failure: String?
    let cancel: () -> Void
    let add: (String) -> Void

    @AppStorage(NectoFontPreference.codeKey) private var codeFontFamily = NectoFontPreference.defaultCode
    @State private var address = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NectoDialog(
            title: NectoL10n.text("Install from GitHub"),
            caption: NectoL10n.text("Necto reads the release, then shows what the plugin binds to before installing it."),
            scale: scale
        ) {
            VStack(alignment: .leading, spacing: 12) {
                NectoField(
                    placeholder: "github.com/owner/plugin",
                    text: $address,
                    scale: scale
                )
                .focused($isFocused)
                .onSubmit { submit() }

                VStack(alignment: .leading, spacing: 6) {
                    form(
                        "github.com/owner/plugin",
                        NectoL10n.text("The latest release.")
                    )
                    form(
                        "github.com/owner/plugin@1.2.0",
                        NectoL10n.text("That release.")
                    )
                    form(
                        "…/releases/tag/1.2.0",
                        NectoL10n.text("A release page, pasted as it is.")
                    )
                }

                if let failure {
                    NectoNotice(
                        title: NectoL10n.text("Could not read that"),
                        detail: failure,
                        isDanger: true,
                        scale: scale
                    )
                }
            }
        } actions: {
            Button(NectoL10n.text("Cancel")) { cancel() }
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                .keyboardShortcut(.cancelAction)

            Button(isReading ? NectoL10n.text("Reading…") : NectoL10n.text("Add")) { submit() }
                .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
                .disabled(trimmed.isEmpty || isReading)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { isFocused = true }
    }

    /// One address shape and what it gets you. Monospaced, because it is something to
    /// copy the shape of rather than to read.
    @ViewBuilder
    private func form(_ address: String, _ means: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(address)
                .font(.necto(.caption, scale: scale, family: codeFontFamily))
                .foregroundStyle(NectoTheme.textSecondary)
                // An address that has been shortened to fit is no longer an address.
                .fixedSize()
            Text(means)
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(NectoTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !isReading else { return }
        add(trimmed)
    }
}
