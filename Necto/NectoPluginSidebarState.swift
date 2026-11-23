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
        _ kind: NectoPluginSidebarStore.Kind, _ change: (inout NectoPluginSidebarSection) throws -> Result
    ) throws -> Result {
        var updated = self[kind]
        let result = try change(&updated)
        try store.save(updated, for: kind)
        sections[kind] = updated
        return result
    }

    /// A section with folders requires a folder-aware reorder.
    @discardableResult
    func saveFlatOrder(_ ids: [String], for kind: NectoPluginSidebarStore.Kind) -> Bool {
        do {
            let updated = try store.saveFlatOrder(ids, for: kind)
            sections[kind] = updated
            return true
        } catch NectoPluginSidebarStore.StorageError.sectionContainsFolders {
            return false
        } catch {
            Self.logger.error("Could not save the \(kind.rawValue, privacy: .public) plugin sidebar order.")
            return false
        }
    }
}

extension NectoPluginSidebarSection {
    struct Row: Identifiable {
        enum ID: Hashable {
            case plugin(String)
            case folder(UUID)
        }

        let item: Item
        let depth: Int

        var id: ID {
            switch item {
            case .plugin(let id): .plugin(id)
            case .folder(let folder): .folder(folder.id)
            }
        }
    }

    func visibleRows(activePluginIDs: [String], disabledPluginIDs: [String]) -> [Row] {
        let availableIDs = activePluginIDs + disabledPluginIDs
        let available = Set(availableIDs)
        let disabled = Set(disabledPluginIDs)
        var placed = Set<String>()
        var rows: [Row] = []

        func visit(_ items: [Item], depth: Int, visible: Bool) {
            for item in items {
                switch item {
                case .plugin(let id):
                    // Keep the existing root-level disabled area. Nested rows keep their saved positions.
                    guard depth > 1 || !disabled.contains(id) else { continue }
                    placed.insert(id)
                    if visible && available.contains(id) { rows.append(Row(item: item, depth: depth)) }
                case .folder(let folder):
                    if visible { rows.append(Row(item: item, depth: depth)) }
                    // Descendants of collapsed folders still own their saved placements.
                    visit(folder.children, depth: depth + 1, visible: visible && !folder.isCollapsed)
                }
            }
        }

        visit(items, depth: 1, visible: true)
        for id in availableIDs where placed.insert(id).inserted {
            rows.append(Row(item: .plugin(id), depth: 1))
        }
        return rows
    }
}
