//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

/// The row the traffic lights sit in. One height across both columns, so the sidebar and
/// the plugin beside it start on the same line.
struct TitleBar<Content: View>: View {
    let leadingInset: CGFloat
    let scale: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(height: 38, alignment: .center)
    }
}

/// What screen you are on, for the window toolbar. Not its version — the sidebar row
/// already says that, and the same fact twice on one screen is noise.
///
/// Wrapped in a `Button` with no border rather than left as a bare `HStack`: a toolbar
/// item that is not a recognised control gets AppKit's own capsule behind it, and that
/// capsule is not in the design.
struct ScreenHeading: View {
    let systemImage: String
    let title: String
    var help: String?
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(NectoTheme.textSecondary)

            Text(title)
                .foregroundStyle(NectoTheme.text)
        }
        .font(.necto(.label, scale: scale))
        .fixedSize()
        .padding(.leading, 4)
        .help(help ?? title)
    }
}
