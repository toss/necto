//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoMacService
import NectoModel
import SwiftUI

/// Which plugins to take out of a release that holds more than one.
///
/// The list is drawn from manifests published beside the archives, so a repository
/// with a dozen plugins in it costs a dozen small files to describe rather than a
/// dozen downloads. A publisher who attached only archives is not doing anything
/// wrong — the row falls back to the file name, and what it binds is read from the
/// archive itself on the approval screen that follows.
///
/// Each row installs on its own, because each is approved on its own: an approval is a
/// decision about one plugin's bridges, and there is nothing for a selection to save
/// when the screen after it appears once per plugin anyway. Installing two is two
/// buttons, and the list stays open until it is closed.
struct PluginChoiceSheet: View {
    let choice: NectoAppModel.PendingChoice
    let scale: CGFloat
    let installed: Set<String>
    let isBusy: Bool
    /// The one being fetched, if any.
    let fetching: String?
    let cancel: () -> Void
    let install: (NectoReleaseSource.Offer) -> Void

    var body: some View {
        NectoDialog(
            title: NectoL10n.format("Install from %@", choice.repository.label),
            caption: NectoL10n.format(
                "%@ holds %@ plugins. Each one is approved on its own screen.",
                choice.release.tag,
                String(choice.release.offers.count)
            ),
            scale: scale
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(choice.release.offers) { offer in
                    row(for: offer)

                    if offer.id != choice.release.offers.last?.id {
                        Rectangle()
                            .fill(NectoTheme.border)
                            .frame(height: 1)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: NectoTheme.radiusControl)
                    .stroke(NectoTheme.border, lineWidth: 1)
            )
        } actions: {
            Button(NectoL10n.text("Done")) { cancel() }
                .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func row(for offer: NectoReleaseSource.Offer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(of: offer))
                    .font(.necto(.label, scale: scale).weight(.medium))
                    .foregroundStyle(NectoTheme.text)

                if let detail = detail(of: offer) {
                    Text(detail)
                        .font(.necto(.caption, scale: scale))
                        .foregroundStyle(NectoTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Already here says more than a disabled button: what is wanted is the
            // plugin, and it is already installed.
            if let id = offer.manifest?.id, installed.contains(id) {
                Text(NectoL10n.text("Installed"))
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                    .padding(.horizontal, 10)
            } else {
                // The app says what it is doing in the control that was pressed, the
                // way the updater does. A share of the download would say more and is
                // not knowable on the path most installs take.
                Button(fetching == offer.assetName ? NectoL10n.text("Installing…") : NectoL10n.text("Install")) {
                    install(offer)
                }
                .buttonStyle(NectoButtonStyle(scale: scale))
                .accessibilityLabel(NectoL10n.format("Install %@", title(of: offer)))
                .disabled(isBusy)
            }
        }
        .padding(10)
    }

    private func title(of offer: NectoReleaseSource.Offer) -> String {
        offer.manifest?.name ?? offer.assetName
    }

    /// What it binds is the part worth reading before agreeing to anything, so it comes
    /// before the description when both are known.
    private func detail(of offer: NectoReleaseSource.Offer) -> String? {
        guard let manifest = offer.manifest else {
            return NectoL10n.text("The release says nothing about this one. What it binds is on the next screen.")
        }
        let bridges = Set(manifest.operations.map(\.binding.name)).sorted()
        return "\(manifest.version) · \(bridges.joined(separator: ", "))"
    }
}
