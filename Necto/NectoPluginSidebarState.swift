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
        var isDimmed = false

        var id: ID {
            switch item {
            case .plugin(let id): .plugin(id)
            case .folder(let folder): .folder(folder.id)
            }
        }
    }

    func visibleRows(activePluginIDs: [String], disabledPluginIDs: [String]) -> [Row] {
        let availableIDs = activePluginIDs + disabledPluginIDs
        let active = Set(activePluginIDs)
        let disabled = Set(disabledPluginIDs)
        let available = active.union(disabled)
        var placed = Set<String>()

        func visit(_ items: [Item], depth: Int, visible: Bool) -> (rows: [Row], hasPlugins: Bool, hasActivePlugin: Bool) {
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
                        normal.append(Row(item: item, depth: depth, isDimmed: isDisabled))
                    }
                case .folder(let folder):
                    // Collapsed children still affect the folder's state and own their saved placements.
                    let children = visit(folder.children, depth: depth + 1, visible: visible && !folder.isCollapsed)
                    hasPlugins = hasPlugins || children.hasPlugins
                    hasActivePlugin = hasActivePlugin || children.hasActivePlugin
                    guard visible else { continue }

                    let isDimmed = children.hasPlugins && !children.hasActivePlugin
                    let row = Row(item: item, depth: depth, isDimmed: isDimmed)
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
                    normal.append(Row(item: .plugin(id), depth: 1, isDimmed: disabled.contains(id)))
                }
            }
            return (normal + dimmedFolders, hasPlugins, hasActivePlugin)
        }

        return visit(items, depth: 1, visible: true).rows
    }
}
