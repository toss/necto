//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI
import UniformTypeIdentifiers

/// Drop regions layered over the native list rows.
struct NectoPluginSidebarDropTarget: View {
    enum Highlight {
        case folder(height: CGFloat)
        case insertion(Alignment)

        var alignment: Alignment {
            switch self {
            case .folder: .center
            case .insertion(let alignment): alignment
            }
        }
    }

    let highlight: Highlight
    let acceptsDrop: () -> Bool
    let allowsDrop: () -> Bool
    let receive: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Color.clear
            .onDrop(
                of: [.text],
                delegate: Destination(
                    isTargeted: $isTargeted,
                    acceptsDrop: acceptsDrop,
                    allowsDrop: allowsDrop,
                    receive: receive
                )
            )
            .overlay(alignment: highlight.alignment) {
                if isTargeted && allowsDrop() {
                    Group {
                        switch highlight {
                        case .folder(let height):
                            RoundedRectangle(cornerRadius: NectoTheme.radiusControl)
                                .strokeBorder(NectoTheme.accent, lineWidth: 1)
                                .frame(height: height)
                        case .insertion:
                            Rectangle().fill(NectoTheme.accent).frame(height: 1)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }

    private struct Destination: DropDelegate {
        @Binding var isTargeted: Bool
        let acceptsDrop: () -> Bool
        let allowsDrop: () -> Bool
        let receive: ([NSItemProvider]) -> Bool

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.text]) && acceptsDrop()
        }

        func dropEntered(info: DropInfo) { isTargeted = allowsDrop() }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            let allowed = allowsDrop()
            isTargeted = allowed
            return DropProposal(operation: allowed ? .move : .forbidden)
        }

        func dropExited(info: DropInfo) { isTargeted = false }

        func performDrop(info: DropInfo) -> Bool {
            isTargeted = false
            return receive(info.itemProviders(for: [.text]))
        }
    }
}
