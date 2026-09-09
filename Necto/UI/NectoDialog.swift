//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

/// `.necto-dialog`. Asking is a modal act: the answer decides what happens next, and
/// there is no sensible way to keep working underneath the question.
///
/// Ours rather than `NSAlert`, which arrives in the system font at the system's own
/// sizes and cannot hold a control drawn from the tokens. The file picker stays the
/// system's — that one is the OS's job, and a hand-drawn file browser would be worse.
struct NectoDialog<Body: View, Actions: View>: View {
    let title: String
    var caption: String?
    let scale: CGFloat
    @ViewBuilder let content: () -> Body
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.necto(.body, scale: scale).weight(.medium))
                    .foregroundStyle(NectoTheme.text)

                if let caption {
                    Text(caption)
                        .font(.necto(.caption, scale: scale))
                        .foregroundStyle(NectoTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            content()
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Spacer()
                actions()
            }
            .padding(16)
        }
        .frame(width: 460)
        .background(NectoTheme.background)
    }
}

/// `.necto-field`. One line of text the user types into.
struct NectoField: View {
    let placeholder: String
    @Binding var text: String
    let scale: CGFloat
    var fontFamily: String? = nil

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.necto(.label, scale: scale, family: fontFamily))
            .foregroundStyle(NectoTheme.text)
            .padding(.horizontal, 8)
            .frame(height: 24 * scale)
            .background(NectoTheme.surface, in: RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: NectoTheme.radiusControl)
                    .stroke(NectoTheme.borderStrong, lineWidth: 1)
            )
    }
}
