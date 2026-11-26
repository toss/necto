//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoCLIService
import NectoModel
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

    func listForCLI(
        _ kind: NectoPluginSidebarStore.Kind, catalog: [NectoInstalledPlugin], disabledIDs: Set<String>
    ) -> NectoJSONValue {
        let section = self[kind]
        let manifests = Self.catalogManifests(catalog)
        let unplaced = Self.unplacedRootPluginIDs(in: section, kind: kind, manifests: manifests, disabledIDs: disabledIDs)

        func describe(_ item: NectoPluginSidebarSection.Item) -> NectoJSONValue {
            switch item {
            case .folder(let folder):
                return [
                    "kind": "folder", "id": .string(folder.id.uuidString), "name": .string(folder.name),
                    "isCollapsed": .bool(folder.isCollapsed), "children": .array(folder.children.map(describe)),
                ]
            case .plugin(let id):
                let manifest = manifests[id]
                var entry: [String: NectoJSONValue] = [
                    "kind": "plugin", "id": .string(id), "available": .bool(manifest != nil),
                    "enabled": .bool(!disabledIDs.contains(id)),
                ]
                if let manifest {
                    entry["name"] = .string(manifest.name)
                    entry["description"] = .string(manifest.description)
                    entry["version"] = .string(manifest.version)
                }
                return .object(entry)
            }
        }

        let items = section.items + unplaced.map(NectoPluginSidebarSection.Item.plugin)
        return ["section": .string(kind.rawValue), "items": .array(items.map(describe))]
    }

    private static func catalogManifests(_ catalog: [NectoInstalledPlugin]) -> [String: NectoPluginManifest] {
        Dictionary(catalog.map { ($0.id, $0.manifest) }, uniquingKeysWith: { first, _ in first })
    }

    private static func unplacedRootPluginIDs(
        in section: NectoPluginSidebarSection, kind: NectoPluginSidebarStore.Kind,
        manifests: [String: NectoPluginManifest], disabledIDs: Set<String>
    ) -> [String] {
        let placed = Set(section.pluginIDs)
        return manifests.values.filter { !placed.contains($0.id) }.sorted { first, second in
            // Device roots display available, enabled plugins before the disabled ones.
            let firstDisabled = kind == .device && disabledIDs.contains(first.id)
            let secondDisabled = kind == .device && disabledIDs.contains(second.id)
            if firstDisabled != secondDisabled { return !firstDisabled }
            return (first.name, first.id) < (second.name, second.id)
        }.map(\.id)
    }

    @discardableResult
    func edit<Result>(
        _ kind: NectoPluginSidebarStore.Kind,
        _ change: (inout NectoPluginSidebarSection) throws -> Result
    ) throws -> Result {
        let current = self[kind]
        var updated = current
        let result = try change(&updated)
        if updated != current {
            try store.save(updated, for: kind)
            sections[kind] = updated
        }
        return result
    }

    func editFolderForCLI(_ command: NectoSidebarRequest.FolderEdit, in kind: NectoPluginSidebarStore.Kind) throws -> NectoJSONValue {
        try editForCLI(kind) { section in
            let original = section
            let id: UUID
            switch command {
            case .create(let name, let parentID):
                id = try section.createFolder(defaultName: name, in: parentID, revealParent: false)
            case .rename(let folderID, let name):
                id = folderID
                try section.renameFolder(id, to: name)
            case .delete(let folderID):
                id = folderID
                try section.deleteFolder(id)
            }

            let before = original.folder(withID: id)
            let after = section.folder(withID: id)
            guard let folder = after ?? before else { throw NectoPluginSidebarSection.ValidationError.folderNotFound }
            var result: [String: NectoJSONValue] = [
                "section": .string(kind.rawValue), "folderID": .string(id.uuidString),
                "name": .string(folder.name), "changed": .bool(before?.name != after?.name),
            ]
            if case .delete = command { result["deleted"] = true }
            return .object(result)
        }
    }

    func moveForCLI(
        _ command: NectoSidebarRequest.Move, in kind: NectoPluginSidebarStore.Kind,
        catalog: [NectoInstalledPlugin], disabledIDs: Set<String>
    ) throws -> (changed: Bool, parentID: UUID?, name: String?) {
        try editForCLI(kind) { section in
            let unplaced = Self.unplacedRootPluginIDs(
                in: section, kind: kind, manifests: Self.catalogManifests(catalog), disabledIDs: disabledIDs
            )

            func locate(_ reference: NectoSidebarRequest.ItemID) -> ItemLocation? {
                let id = reference.layoutID
                if let location = section.location(of: id) {
                    return ItemLocation(kind: kind, id: id, parentID: location.parentID)
                }
                if case .plugin(let pluginID) = id, unplaced.contains(pluginID) {
                    return ItemLocation(kind: kind, id: id, parentID: nil)
                }
                return nil
            }

            guard let source = locate(command.item) else {
                throw NectoBridgeError(code: .invalidInput, message: "Item '\(command.item.reference)' does not exist in this section.")
            }
            if let parentID = command.parentID, section.folder(withID: parentID) == nil {
                throw NectoPluginSidebarSection.ValidationError.parentFolderNotFound
            }

            let destination: NectoPluginSidebarSection.MoveDestination
            if let reference = command.before ?? command.after {
                guard let anchor = locate(reference) else {
                    throw NectoBridgeError(code: .invalidInput, message: "Anchor '\(reference.reference)' does not exist in this section.")
                }
                if let parentID = command.parentID, parentID != anchor.parentID {
                    throw NectoBridgeError(code: .invalidInput, message: "The anchor is not a child of the specified parent folder.")
                }
                destination = .beside(anchor.id, position: command.before == nil ? .after : .before, parentID: anchor.parentID)
            } else {
                destination = .into(parentID: command.parentID)
            }

            let changed = try section.move(
                source.id, from: source.parentID, to: destination, unplacedRootPluginIDs: unplaced, revealParent: false
            )
            // The source and destination were found above. Detaching the source can
            // only hide the destination if it was the source folder or part of its subtree.
            if !changed, source.parentID != destination.parentID {
                throw NectoBridgeError(code: .invalidInput, message: "A folder cannot move into itself or its descendants.")
            }
            let name: String? = if case .folder(let id) = source.id { section.folder(withID: id)?.name } else { nil }
            return (changed, destination.parentID, name)
        }
    }

    private func editForCLI<Result>(
        _ kind: NectoPluginSidebarStore.Kind, _ change: (inout NectoPluginSidebarSection) throws -> Result
    ) throws -> Result {
        do {
            return try edit(kind, change)
        } catch let error as NectoPluginSidebarSection.ValidationError {
            throw NectoBridgeError(code: .invalidInput, message: error.description)
        } catch NectoPluginSidebarStore.StorageError.invalidSavedSection {
            throw NectoBridgeError(code: .providerFailed, message: "The saved \(kind.rawValue) sidebar is invalid and could not be updated.")
        }
    }

    func setEnabled(
        _ plugin: NectoInstalledPlugin, enabled: Bool, availableDevicePluginIDs: [String] = []
    ) throws -> Set<String> {
        let kind: NectoPluginSidebarStore.Kind = plugin.source == .installed ? .desktop : .device
        if !enabled && (kind == .desktop || NectoPluginLibrary.isEnabled(plugin.id, in: store.defaults)) {
            var section = try store.load(kind)
            let changed = try kind == .desktop
                ? section.movePluginToRoot(plugin.id)
                : section.movePluginToEnd(plugin.id, unplacedRootPluginIDs: availableDevicePluginIDs)
            if changed {
                try store.save(section, for: kind)
            }
            if self[kind] != section {
                sections[kind] = section
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
            let siblings = rows.filter { $0.parentID == source.parentID }
            guard siblings.contains(where: { $0.id == source.id }),
                  siblings.contains(where: { $0.id == anchor.id }),
                  try section.reorder(
                    source.id, relativeTo: anchor.id, position: position, in: source.parentID,
                    unplacedRootPluginIDs: activePluginIDs + disabledPluginIDs
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

private extension NectoSidebarRequest.ItemID {
    var layoutID: NectoPluginSidebarSection.Item.ID {
        switch self {
        case .plugin(let id): .plugin(id)
        case .folder(let id): .folder(id)
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
        guard rows.contains(where: { $0.id == source.id && $0.parentID == source.parentID }) else { return nil }
        switch destination {
        case .into(let parentID):
            if let parentID, !rows.contains(where: { $0.id == .folder(parentID) }) { return nil }
        case .beside(let anchor, _, let parentID):
            guard rows.contains(where: { $0.id == anchor && $0.parentID == parentID }) else {
                return nil
            }
        }

        var candidate = self
        guard (try? candidate.move(
            source.id, from: source.parentID, to: destination, unplacedRootPluginIDs: activePluginIDs + disabledPluginIDs
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
        guard let anchor, anchor.parentID == source.parentID, anchor.id != source.id else { return nil }
        return (source, anchor, position)
    }

    /// A row edge belongs to that row's sibling list, even at the end of an expanded subtree.
    static func dropDestination(
        beside id: Item.ID, position: InsertionPosition, in siblings: [Row]
    ) -> MoveDestination? {
        guard let row = siblings.first(where: { $0.id == id }) else { return nil }
        return .beside(id, position: position, parentID: row.parentID)
    }

    func visibleRows(activePluginIDs: [String], disabledPluginIDs: [String]) -> [Row] {
        let availableIDs = activePluginIDs + disabledPluginIDs
        let available = Set(availableIDs)
        let disabled = Set(disabledPluginIDs)

        func visit(_ items: [Item], parentID: UUID?, depth: Int) -> [Row] {
            var rows: [Row] = []
            for item in items {
                switch item {
                case .plugin(let id):
                    if available.contains(id) {
                        rows.append(Row(item: item, depth: depth, parentID: parentID, isDimmed: disabled.contains(id)))
                    }
                case .folder(let folder):
                    let children = folder.isCollapsed ? [] : visit(folder.children, parentID: folder.id, depth: depth + 1)
                    rows.append(Row(
                        item: item, depth: depth, parentID: parentID, lastVisibleDescendantID: children.last?.id
                    ))
                    rows.append(contentsOf: children)
                }
            }
            return rows
        }

        var rows = visit(items, parentID: nil, depth: 1)
        // Plugins in a collapsed folder still have a saved placement.
        var placed = Set(pluginIDs)
        for id in availableIDs where placed.insert(id).inserted {
            rows.append(Row(item: .plugin(id), depth: 1, parentID: nil, isDimmed: disabled.contains(id)))
        }
        return rows
    }
}
