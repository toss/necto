//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

/// The layout pieces from `WebPackages/Bridge/components.css`, in SwiftUI.
/// See `NectoControls.swift` for why the shell has its own set at all.

// MARK: Section title

/// `.necto-section-title`. Caption sized, tertiary coloured, not uppercased.
struct NectoSectionTitle: View {
    let title: String
    let scale: CGFloat
    var isFirst = false
    var fontFamily: String? = nil

    init(_ title: String, scale: CGFloat, isFirst: Bool = false, fontFamily: String? = nil) {
        self.title = title
        self.scale = scale
        self.isFirst = isFirst
        self.fontFamily = fontFamily
    }

    var body: some View {
        Text(title)
            .font(.necto(.caption, scale: scale, family: fontFamily))
            .foregroundStyle(NectoTheme.textTertiary)
            .padding(.top, isFirst ? 0 : 24)
            .padding(.bottom, 8)
    }
}

// MARK: Row

/// `.necto-row`. Label on the left, the control on the right, a hairline between rows.
/// A settings screen is read down the left edge and operated down the right one.
struct NectoRow<Control: View>: View {
    let label: String
    var hint: String?
    let scale: CGFloat
    var fontFamily: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.necto(.label, scale: scale, family: fontFamily))
                    .foregroundStyle(NectoTheme.text)

                if let hint {
                    Text(hint)
                        .font(.necto(.caption, scale: scale, family: fontFamily))
                        .foregroundStyle(NectoTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
        }
        .padding(.vertical, 8)
        .frame(minHeight: 38)
        .overlay(alignment: .top) {
            Rectangle().fill(NectoTheme.border).frame(height: 1)
        }
    }
}

/// The right-hand side of a row when it is a fact rather than a control.
struct NectoRowValue: View {
    let value: String
    let scale: CGFloat

    var body: some View {
        Text(value)
            .font(.necto(.label, scale: scale))
            .foregroundStyle(NectoTheme.textSecondary)
    }
}

// MARK: Nav

/// `.necto-nav`. A column of destinations inside one screen. The sidebar navigates the
/// app; this navigates whatever screen is already open.
struct NectoNav<Value: Hashable>: View {
    static var defaultWidth: CGFloat { 180 }

    let items: [(value: Value, label: String, systemImage: String)]
    let selection: Value
    let scale: CGFloat
    /// Persisted by the owner; the border is a handle, so a label that outgrows the
    /// column is dragged out of its trouble rather than truncated forever.
    @Binding var width: CGFloat
    let select: (Value) -> Void

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                NectoNavItem(
                    label: item.label,
                    systemImage: item.systemImage,
                    isSelected: item.value == selection,
                    scale: scale
                ) { select(item.value) }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .frame(width: max(width, 120), alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(NectoTheme.border).frame(width: 1)
        }
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    // Global space, because the handle itself moves with every width
                    // change: measured locally, its own motion feeds back into the
                    // translation and the drag shivers.
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = widthAtDragStart ?? width
                            widthAtDragStart = start
                            width = min(max(start + value.translation.width, 120), 340)
                        }
                        .onEnded { _ in widthAtDragStart = nil }
                )
        }
    }
}

struct NectoNavItem: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let scale: CGFloat
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(NectoTheme.textTertiary)
                    .frame(width: 16)

                Text(label).lineLimit(1)

                Spacer(minLength: 0)
            }
            .font(.necto(.label, scale: scale))
            .foregroundStyle(isSelected || isHovering ? NectoTheme.text : NectoTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: NectoTheme.rowHeight * scale)
            .background(background, in: RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }

    private var background: Color {
        if isSelected { return NectoTheme.selected }
        return isHovering ? NectoTheme.hover : .clear
    }
}

// MARK: Pairs

/// `.necto-pairs`. One label column for the whole list, so values line down the pane
/// instead of stepping in and out with the length of each name.
struct NectoPairs: View {
    let rows: [(String, String)]
    let scale: CGFloat

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { key, value in
                GridRow {
                    Text(key)
                        .font(.necto(.label, scale: scale))
                        .foregroundStyle(NectoTheme.textTertiary)
                    Text(value)
                        .font(.necto(.label, scale: scale))
                        .foregroundStyle(NectoTheme.text)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: Notice

/// `.necto-notice`. Says what went wrong and what to do about it, on the surface it
/// happened on.
struct NectoNotice: View {
    let title: String
    let detail: String
    var isDanger = false
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(isDanger ? NectoTheme.danger : NectoTheme.textTertiary)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.text)
                Text(detail)
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NectoTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: NectoTheme.radiusControl)
                .stroke(NectoTheme.border, lineWidth: 1)
        )
    }
}

// MARK: Empty

/// `.necto-empty`. Says what is missing and what to do next, in two lines at most. It
/// never advertises features.
struct NectoEmpty: View {
    let title: String
    let detail: String
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.necto(.body, scale: scale))
                .foregroundStyle(NectoTheme.textSecondary)
            Text(detail)
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(NectoTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
