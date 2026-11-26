//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The drop regions occupy the native row label without changing its layout.
struct NectoPluginSidebarDropTarget: View {
    typealias Section = NectoPluginSidebarSection

    @MainActor
    @Observable
    final class Feedback {
        var highlight: Highlight?
        var nativeReorderSource: NectoPluginSidebarState.ItemLocation?

        func clear() {
            highlight = nil
            nativeReorderSource = nil
        }
    }

    struct Highlight: Equatable {
        enum Position {
            case before, center, after
        }

        let kind: NectoPluginSidebarStore.Kind
        let targetRow: Section.Item.ID
        let displayRow: Section.Item.ID
        let position: Position
        var leadingExtension: CGFloat = 0
    }

    let kind: NectoPluginSidebarStore.Kind
    let rowID: Section.Item.ID
    let parentID: UUID?
    let before: Section.MoveDestination?
    let center: Section.MoveDestination?
    let after: Section.MoveDestination?
    let afterRowID: Section.Item.ID
    let afterLeadingExtension: CGFloat
    let feedback: Feedback
    let acceptsDrop: () -> Bool
    let allowsDrop: (Section.MoveDestination) -> Bool
    let receive: (Section.MoveDestination, [NSItemProvider]) -> Bool

    var body: some View {
        GeometryReader { geometry in
            let edgeHeight = geometry.size.height * (center == nil ? 0.5 : 0.22)
            VStack(spacing: 0) {
                region(before, position: .before)
                    .frame(height: edgeHeight)
                if let center {
                    region(center, position: .center)
                }
                region(after, position: .after)
                    .frame(height: edgeHeight)
            }
            .overlay {
                if let highlight = feedback.highlight, highlight.kind == kind, highlight.displayRow == rowID {
                    indicator(for: highlight)
                        .padding(.leading, -2 - highlight.leadingExtension)
                        .padding(.trailing, 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func region(_ destination: Section.MoveDestination?, position: Highlight.Position) -> some View {
        if position != .center, destination != nil,
           let source = feedback.nativeReorderSource, source.kind == kind, source.parentID == parentID {
            // Leave no custom hit target over native reorder edges.
            Color.clear.allowsHitTesting(false)
        } else {
            let highlight = Highlight(
                kind: kind, targetRow: rowID, displayRow: position == .after ? afterRowID : rowID,
                position: position, leadingExtension: position == .after ? afterLeadingExtension : 0
            )
            Color.clear.onDrop(
                of: [.text],
                delegate: Destination(
                    feedback: feedback, highlight: highlight, acceptsDrop: acceptsDrop,
                    allowsDrop: { destination.map(allowsDrop) ?? false },
                    receive: { providers in destination.map { receive($0, providers) } ?? false }
                )
            )
        }
    }

    @ViewBuilder
    private func indicator(for highlight: Highlight) -> some View {
        switch highlight.position {
        case .center:
            RoundedRectangle(cornerRadius: NectoTheme.radiusControl)
                .strokeBorder(NectoTheme.accent, lineWidth: 1)
        case .before, .after:
            Rectangle()
                .fill(NectoTheme.accent)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: highlight.position == .before ? .top : .bottom)
        }
    }

    private struct Destination: DropDelegate {
        let feedback: Feedback
        let highlight: Highlight
        let acceptsDrop: () -> Bool
        let allowsDrop: () -> Bool
        let receive: ([NSItemProvider]) -> Bool

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.text]) && acceptsDrop()
        }

        func dropEntered(info: DropInfo) { updateHighlight(allowed: allowsDrop()) }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            let allowed = allowsDrop()
            updateHighlight(allowed: allowed)
            return DropProposal(operation: allowed ? .move : .forbidden)
        }

        func dropExited(info: DropInfo) { clearHighlight() }

        func performDrop(info: DropInfo) -> Bool {
            clearHighlight()
            return receive(info.itemProviders(for: [.text]))
        }

        private func updateHighlight(allowed: Bool) {
            let next = allowed ? highlight : nil
            if feedback.highlight != next { feedback.highlight = next }
        }

        private func clearHighlight() {
            if feedback.highlight == highlight { feedback.highlight = nil }
        }
    }
}
