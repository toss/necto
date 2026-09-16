//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoMacService
import SwiftUI

extension View {
    /// A `List` row with none of `List`'s own padding, background or separator, so what
    /// shows is only what the row drew.
    /// `isSelected` is passed only so that selecting a row counts as a change: a
    /// representable with no inputs is never updated again after it is made, and the
    /// highlight it exists to suppress is drawn when the selection moves.
    func plainRow(isSelected: Bool = false) -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // Every row, not just the selectable ones: `List` highlights the focused
            // row too, and that highlight is a full-width band with square ends.
            .background(ListChromeOff(isSelected: isSelected))
    }
}

/// A heading over a run of rows. Caption sized, secondary coloured, not uppercased.
struct SidebarGroup: View {
    let title: String
    let scale: CGFloat

    var body: some View {
        Text(title)
            .font(.necto(.caption, scale: scale))
            .foregroundStyle(NectoTheme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

/// One row in the sidebar, drawn the same way whatever it points at, so a device and a
/// plugin do not read as two different kinds of control.
struct SidebarItem: View {
    let title: String
    let systemImage: String
    let trailing: String
    /// Draws the trailing text as something to attend to rather than as a version.
    var trailingIsIssue = false
    let isSelected: Bool
    let scale: CGFloat
    /// Sunken: a disabled plugin, present but not in play.
    var isDimmed = false
    var select: (() -> Void)?

    @State private var isHovering = false

    /// A tap rather than a `Button`: a button takes the mouse down for itself, and
    /// `List` never gets the chance to start a drag. Reordering the sidebar is worth
    /// more than the button's own press animation, which this row does not use anyway.
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(NectoTheme.textTertiary)
                .frame(width: 16)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(trailing)
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(trailingIsIssue ? NectoTheme.danger : NectoTheme.textTertiary)
                .lineLimit(1)
        }
        .font(.necto(.label, scale: scale))
        .foregroundStyle(isDimmed ? NectoTheme.textTertiary : isSelected ? NectoTheme.text : NectoTheme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: NectoTheme.rowHeight * scale)
        .background(background, in: RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .onHover { isHovering = $0 }
        .modifier(TapIfPresent(action: select))
    }

    private var background: Color {
        if isSelected { return NectoTheme.selected }
        return isHovering ? NectoTheme.hover : .clear
    }
}

/// Turns off the chrome `NSTableView` draws over our own, and gives its enclosing
/// scroll view a narrow, fixed scrollbar track.
///
/// The highlight is a full-width band with square ends, which is not the selection in
/// docs/design.md — the row draws that itself, inset and rounded.
///
/// Only the highlight. The drop indicator that appears while a row is being dragged is
/// left at AppKit's default: its colour follows the system accent and its thickness is
/// not settable, and the one alternative worth having — `.gap`, where the rows part to
/// show where the row will land — traps in SwiftUI when a row is dragged out of the
/// list, because `NSOutlineView` re-validates the drop from `draggingExited:` and
/// `ListOutlineItem.item(forRowAt:)` then reads past the end of the row ids.
///
/// There is no SwiftUI spelling for this, so it is reached through the view it belongs
/// to. Applied on every update because a row view is reused as the list scrolls.
private struct ListChromeOff: NSViewRepresentable {
    let isSelected: Bool

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        // A row has no ancestors yet while it is being made.
        DispatchQueue.main.async { apply(from: view) }
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        apply(from: view)
    }

    private func apply(from view: NSView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let row = current as? NSTableRowView {
                row.selectionHighlightStyle = .none
            }
            if let table = current as? NSTableView {
                table.selectionHighlightStyle = .none
            }
            if let scrollView = current as? NSScrollView {
                // An overlay scroller changes the List's content inset when selection
                // scrolls a row into view. A legacy scroller reserves one stable gutter.
                if scrollView.scrollerStyle != .legacy {
                    scrollView.scrollerStyle = .legacy
                }
                if scrollView.autohidesScrollers {
                    scrollView.autohidesScrollers = false
                }
                if scrollView.verticalScroller?.controlSize != .mini {
                    scrollView.verticalScroller?.controlSize = .mini
                }
                return
            }
            ancestor = current.superview
        }
    }
}

/// A row inside a `List` must let the click through to `List`, which is what selects
/// it. Rows outside one — Settings, at the foot — handle their own.
private struct TapIfPresent: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// The app a plugin is written for, with its bundle id underneath.
///
/// The app is the heading because the same one is commonly running on several devices
/// at once, and it is the devices that are the choice.
struct AppHeader: View {
    let name: String
    let bundleID: String
    let iconData: Data?
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.text)
                    .lineLimit(1)

                Text(bundleID)
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// The app's own icon when it sent one, so it reads the way the user knows it.
    @ViewBuilder
    private var icon: some View {
        if let iconData, let image = NSImage(data: iconData) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
        } else {
            Image(systemName: "app.dashed")
                .font(.necto(.title, scale: scale))
                .foregroundStyle(NectoTheme.textSecondary)
                .frame(width: 26, height: 26)
        }
    }
}

/// One device the app is running on. Selecting it is what points a plugin somewhere.
struct DeviceRow: View {
    let device: NectoConnectedApp
    let isSelected: Bool
    let scale: CGFloat
    let select: () -> Void

    @State private var isHovering = false

    private var isSimulator: Bool { device.connection.isEmulator }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                // A simulator is an iPhone running on a Mac, and the symbol says
                // exactly that. It is wider than the plain phone, so both sit in a
                // fixed width and the names below stay in line.
                Image(systemName: isSimulator ? "laptopcomputer.and.iphone" : "iphone")
                    .foregroundStyle(NectoTheme.textTertiary)
                    .frame(width: 16)

                Text(device.deviceName)
                    .foregroundStyle(isSelected ? NectoTheme.text : NectoTheme.textSecondary)
                    .lineLimit(1)
                    // The name is the only part whose length cannot be predicted, so
                    // it keeps the room when something has to give.
                    .layoutPriority(1)

                Spacer(minLength: 6)

                if !device.osVersion.isEmpty {
                    Text("\(device.connection.osName) \(device.osVersion)")
                        .font(.necto(.caption, scale: scale))
                        .foregroundStyle(NectoTheme.textTertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                // Says one thing only: this target is attached. Whether it is a device
                // or a simulator belongs to the symbol on the left.
                Circle()
                    .fill(NectoTheme.success)
                    .frame(width: 6, height: 6)
            }
            .font(.necto(.label, scale: scale))
            .padding(.horizontal, 8)
            .frame(height: NectoTheme.rowHeight * scale)
            .background(background, in: RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovering = $0 }
        // Nothing is only in the row: hovering gives the whole thing.
        .help(tooltip)
    }

    private var background: Color {
        if isSelected { return NectoTheme.selected }
        return isHovering ? NectoTheme.hover : .clear
    }

    private var tooltip: String {
        [
            device.deviceName + (isSimulator ? " (\(NectoL10n.text("Simulator")))" : ""),
            NectoL10n.text(isSimulator ? "Connected over loopback" : "Connected over USB"),
            device.osVersion.isEmpty ? nil : "\(device.connection.osName) \(device.osVersion)",
            device.appBundleID,
            device.appVersion.isEmpty ? nil : NectoL10n.format("App %@", device.appVersion),
            NectoL10n.format("Necto SDK %@", device.sdkVersion),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}
