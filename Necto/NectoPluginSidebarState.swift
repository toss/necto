//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Observation
import OSLog

/// The saved sidebar shared by all windows. The selected app and row belong to each window.
@MainActor
@Observable
final class NectoPluginSidebarState {
    struct ItemLocation: Equatable, Sendable {
        let kind: NectoPluginSidebarStore.Kind
        let id: NectoPluginSidebarSection.Item.ID
        let parentID: UUID?
    }

    private static let logger = Logger(subsystem: "Necto", category: "PluginSidebar")
    private let store: NectoPluginSidebarStore
    private var sections: [NectoPluginSidebarStore.Kind: NectoPluginSidebarSection]

    init(store: NectoPluginSidebarStore) {
        self.store = store
        sections = [:]
        for kind in NectoPluginSidebarStore.Kind.allCases {
            do {
                sections[kind] = try store.load(kind)
            } catch {
                Self.logger.error("Could not load the \(kind.rawValue, privacy: .public) plugin sidebar section.")
            }
        }
    }

    subscript(_ kind: NectoPluginSidebarStore.Kind) -> NectoPluginSidebarSection {
        sections[kind] ?? NectoPluginSidebarSection()
    }

    @discardableResult
    func edit<Result>(
        _ kind: NectoPluginSidebarStore.Kind,
        _ change: (inout NectoPluginSidebarSection) throws -> Result
    ) throws -> Result {
        var updated = self[kind]
        let result = try change(&updated)
        try store.save(updated, for: kind)
        sections[kind] = updated
        return result
    }

    func setEnabled(_ plugin: NectoInstalledPlugin, enabled: Bool) throws -> Set<String> {
        if plugin.source == .installed && !enabled {
            var section = try store.load(.desktop)
            if try section.movePluginToRoot(plugin.id) {
                try store.save(section, for: .desktop)
            }
            if self[.desktop] != section {
                sections[.desktop] = section
            }
        }
        return NectoPluginLibrary.setEnabled(plugin.id, enabled, in: store.defaults)
    }

    @discardableResult
    func reorder(
        _ source: ItemLocation,
        relativeTo anchor: ItemLocation,
        position: NectoPluginSidebarSection.InsertionPosition,
        activePluginIDs: [String],
        disabledPluginIDs: [String]
    ) -> Bool {
        guard source.kind == anchor.kind, source.parentID == anchor.parentID, source.id != anchor.id else { return false }
        let kind = source.kind
        do {
            var section = try store.load(kind)
            let rows = section.visibleRows(activePluginIDs: activePluginIDs, disabledPluginIDs: disabledPluginIDs)
            let siblings = rows.filter { $0.parentID == source.parentID && $0.canReorder }
            guard siblings.contains(where: { $0.id == source.id }),
                  siblings.contains(where: { $0.id == anchor.id }),
                  try section.reorder(
                    source.id, relativeTo: anchor.id, position: position, in: source.parentID,
                    unplacedRootPluginIDs: activePluginIDs
                  ) else { return false }
            try store.save(section, for: kind)
            sections[kind] = section
            return true
        } catch {
            Self.logger.error("Could not save the \(kind.rawValue, privacy: .public) plugin sidebar order.")
            return false
        }
    }

    @discardableResult
    func move(
        _ source: ItemLocation,
        to destination: NectoPluginSidebarSection.MoveDestination,
        in kind: NectoPluginSidebarStore.Kind,
        activePluginIDs: [String],
        disabledPluginIDs: [String]
    ) -> Bool {
        guard let updated = self[kind].candidateForMove(
            source,
            to: destination,
            in: kind,
            activePluginIDs: activePluginIDs,
            disabledPluginIDs: disabledPluginIDs
        ) else { return false }
        do {
            try store.save(updated, for: kind)
            sections[kind] = updated
            return true
        } catch {
            Self.logger.error("Could not save the \(kind.rawValue, privacy: .public) plugin sidebar move.")
            return false
        }
    }
}

extension NectoPluginSidebarSection {
    /// The same candidate used for drop feedback and before saving against the latest section.
    func candidateForMove(
        _ source: NectoPluginSidebarState.ItemLocation,
        to destination: MoveDestination,
        in kind: NectoPluginSidebarStore.Kind,
        activePluginIDs: [String],
        disabledPluginIDs: [String]
    ) -> Self? {
        guard source.kind == kind, source.parentID != destination.parentID else { return nil }
        let rows = visibleRows(activePluginIDs: activePluginIDs, disabledPluginIDs: disabledPluginIDs)
        guard let sourceRow = rows.first(where: { $0.id == source.id && $0.parentID == source.parentID }),
              sourceRow.canChangeParent(in: kind) else { return nil }
        switch destination {
        case .into(let parentID):
            if let parentID, !rows.contains(where: { $0.id == .folder(parentID) }) { return nil }
        case .beside(let anchor, _, let parentID):
            guard rows.contains(where: { $0.id == anchor && $0.parentID == parentID && $0.canReorder }) else {
                return nil
            }
        }

        // A root disabled source may be available but not yet present in the saved section.
        var rootPluginIDs = activePluginIDs
        if sourceRow.isDimmed, source.parentID == nil, case .plugin(let id) = source.id {
            rootPluginIDs.append(id)
        }
        var candidate = self
        guard (try? candidate.move(
            source.id, from: source.parentID, to: destination, unplacedRootPluginIDs: rootPluginIDs
        )) == true else { return nil }
        return candidate
    }

    struct Row: Identifiable {
        let item: Item
        let depth: Int
        let parentID: UUID?
        var isDimmed = false
        var lastVisibleDescendantID: Item.ID?

        var id: Item.ID { item.id }

        var canReorder: Bool {
            switch item {
            case .plugin: parentID != nil || !isDimmed
            case .folder: !isDimmed
            }
        }

        func canChangeParent(in kind: NectoPluginSidebarStore.Kind) -> Bool {
            switch item {
            case .plugin: !isDimmed || kind == .device
            case .folder: !isDimmed
            }
        }
    }

    /// Each disclosure group gives its ForEach the immediate children in their displayed order.
    func visibleSiblings(activePluginIDs: [String], disabledPluginIDs: [String]) -> [UUID?: [Row]] {
        let rows = visibleRows(activePluginIDs: activePluginIDs, disabledPluginIDs: disabledPluginIDs)
        return Dictionary(grouping: rows.map { row in
            var sibling = row
            // The descendants are elements of a different ForEach, not part of this insertion offset.
            sibling.lastVisibleDescendantID = nil
            return sibling
        }, by: \.parentID)
    }

    static func insertion(
        from sources: IndexSet,
        to destination: Int,
        in rows: [Row]
    ) -> (source: Row, anchor: Row, position: InsertionPosition)? {
        guard sources.count == 1, let index = sources.first, rows.indices.contains(index),
              (0...rows.count).contains(destination) else { return nil }
        let source = rows[index]
        guard source.canReorder else { return nil }

        let position: InsertionPosition = destination > index ? .after : .before
        let anchor: Row?
        if position == .before {
            anchor = rows[destination]
        } else {
            // An expanded folder's after-boundary follows its last visible descendant.
            let precedingID = rows[destination - 1].id
            anchor = rows.first {
                $0.parentID == source.parentID && ($0.lastVisibleDescendantID ?? $0.id) == precedingID
            }
        }
        guard let anchor, anchor.parentID == source.parentID, anchor.canReorder, anchor.id != source.id else { return nil }
        return (source, anchor, position)
    }

    func visibleRows(activePluginIDs: [String], disabledPluginIDs: [String]) -> [Row] {
        let availableIDs = activePluginIDs + disabledPluginIDs
        let active = Set(activePluginIDs)
        let disabled = Set(disabledPluginIDs)
        let available = active.union(disabled)
        var placed = Set<String>()

        func visit(
            _ items: [Item],
            parentID: UUID?,
            depth: Int,
            visible: Bool
        ) -> (rows: [Row], hasPlugins: Bool, hasActivePlugin: Bool) {
            var normal: [Row] = []
            var dimmedFolders: [Row] = []
            var hasPlugins = false
            var hasActivePlugin = false

            for item in items {
                switch item {
                case .plugin(let id):
                    hasPlugins = true
                    hasActivePlugin = hasActivePlugin || active.contains(id)

                    // Keep the existing root-level disabled area. Nested rows keep their saved positions.
                    let isDisabled = disabled.contains(id)
                    guard depth > 1 || !isDisabled else { continue }
                    placed.insert(id)
                    if visible && available.contains(id) {
                        normal.append(Row(item: item, depth: depth, parentID: parentID, isDimmed: isDisabled))
                    }
                case .folder(let folder):
                    // Collapsed children still affect the folder's state and own their saved placements.
                    let children = visit(
                        folder.children, parentID: folder.id, depth: depth + 1, visible: visible && !folder.isCollapsed
                    )
                    hasPlugins = hasPlugins || children.hasPlugins
                    hasActivePlugin = hasActivePlugin || children.hasActivePlugin
                    guard visible else { continue }

                    let isDimmed = children.hasPlugins && !children.hasActivePlugin
                    let row = Row(
                        item: item, depth: depth, parentID: parentID, isDimmed: isDimmed,
                        lastVisibleDescendantID: children.rows.last?.id
                    )
                    if isDimmed {
                        dimmedFolders.append(row)
                        dimmedFolders.append(contentsOf: children.rows)
                    } else {
                        normal.append(row)
                        normal.append(contentsOf: children.rows)
                    }
                }
            }

            if depth == 1 {
                // Append new active plugins and the root disabled area before dimmed root folders.
                for id in availableIDs where placed.insert(id).inserted {
                    normal.append(Row(item: .plugin(id), depth: 1, parentID: nil, isDimmed: disabled.contains(id)))
                }
            }
            return (normal + dimmedFolders, hasPlugins, hasActivePlugin)
        }

        return visit(items, parentID: nil, depth: 1, visible: true).rows
    }
}
