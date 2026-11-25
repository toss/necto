//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// The native List carries opaque strings. Item identities and layout stay in their window.
@MainActor
final class NectoPluginSidebarDrag {
    struct Context: Equatable, Sendable {
        struct Section: Equatable, Sendable {
            let layout: NectoPluginSidebarSection
            let activePluginIDs: [String]
            var disabledPluginIDs: [String] = []
        }

        let target: NectoTarget?
        let device: Section
        let desktop: Section

        subscript(_ kind: NectoPluginSidebarStore.Kind) -> Section {
            kind == .device ? device : desktop
        }
    }

    @MainActor
    private final class Transfer {
        let source: NectoPluginSidebarState.ItemLocation
        let context: Context
        let handle: String
        let provider: NSItemProvider

        init(source: NectoPluginSidebarState.ItemLocation, context: Context) {
            self.source = source
            self.context = context
            handle = UUID().uuidString
            provider = NSItemProvider(object: handle as NSString)
        }
    }

    private var transfer: Transfer?
    private var pendingDrop: UUID?

    func provider(
        for source: NectoPluginSidebarState.ItemLocation,
        in context: Context
    ) -> NSItemProvider {
        pendingDrop = nil
        // List can request more than one provider for the same drag.
        if let transfer, transfer.source == source, transfer.context == context {
            return transfer.provider
        }
        let transfer = Transfer(source: source, context: context)
        self.transfer = transfer
        return transfer.provider
    }

    func clear() {
        transfer = nil
        pendingDrop = nil
    }

    func takeNativeSource(in context: Context) -> NectoPluginSidebarState.ItemLocation? {
        guard let transfer else { return nil }
        clear()
        return transfer.context == context ? transfer.source : nil
    }

    func acceptsDrop(in context: Context) -> Bool {
        transfer?.context == context
    }

    func source(in context: Context) -> NectoPluginSidebarState.ItemLocation? {
        guard let transfer, transfer.context == context else { return nil }
        return transfer.source
    }

    func allowsDrop(
        to destination: NectoPluginSidebarSection.MoveDestination,
        in kind: NectoPluginSidebarStore.Kind,
        context: Context
    ) -> Bool {
        guard let transfer, transfer.context == context else { return false }
        let section = context[kind]
        return section.layout.candidateForMove(
            transfer.source,
            to: destination,
            in: kind,
            activePluginIDs: section.activePluginIDs,
            disabledPluginIDs: section.disabledPluginIDs
        ) != nil
    }

    func receive(
        _ providers: [NSItemProvider],
        context: Context,
        currentContext: @escaping @MainActor () -> Context,
        move: @escaping @MainActor (NectoPluginSidebarState.ItemLocation) -> Void
    ) -> Bool {
        guard let transfer, transfer.context == context else { return false }
        clear()
        guard providers.count == 1, let provider = providers.first,
              provider.canLoadObject(ofClass: NSString.self) else { return false }
        let receipt = UUID()
        pendingDrop = receipt
        _ = provider.loadObject(ofClass: NSString.self) { object, error in
            let handle = object as? String
            Task { @MainActor in
                guard self.pendingDrop == receipt else { return }
                self.clear()
                guard error == nil, handle == transfer.handle,
                      context == currentContext() else { return }
                move(transfer.source)
            }
        }
        return true
    }
}
