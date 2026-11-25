//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// The arrangement of one sidebar section, independent of which plugins are available.
struct NectoPluginSidebarSection: Equatable, Sendable {
    enum Item: Codable, Equatable, Identifiable, Sendable {
        enum ID: Hashable, Sendable {
            case plugin(String)
            case folder(UUID)
        }

        case plugin(String)
        case folder(Folder)

        var id: ID {
            switch self {
            case .plugin(let id): .plugin(id)
            case .folder(let folder): .folder(folder.id)
            }
        }
    }

    enum InsertionPosition: Sendable {
        case before
        case after
    }

    enum MoveDestination: Sendable {
        case into(parentID: UUID?)
        case beside(Item.ID, position: InsertionPosition, parentID: UUID?)

        var parentID: UUID? {
            switch self {
            case .into(let parentID), .beside(_, _, let parentID): parentID
            }
        }
    }

    struct Folder: Codable, Equatable, Sendable {
        let id: UUID
        var name: String
        var children: [Item]
        var isCollapsed: Bool

        init(id: UUID = UUID(), name: String, children: [Item] = [], isCollapsed: Bool = false) {
            self.id = id
            self.name = name
            self.children = children
            self.isCollapsed = isCollapsed
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case children
            case isCollapsed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            children = try container.decode([Item].self, forKey: .children)
            isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        }
    }

    enum ValidationError: Error, Equatable {
        case emptyFolderName
        case duplicateFolderName
        case duplicateFolderID
        case duplicatePluginID
        case folderDepthExceeded
        case parentFolderNotFound
        case folderNotFound
    }

    static let maximumFolderDepth = 3

    private(set) var items: [Item]

    init() {
        items = []
    }

    init(items: [Item]) throws {
        var pluginIDs = Set<String>()
        var folderIDs = Set<UUID>()
        self.items = try Self.validatedItems(items, depth: 1, pluginIDs: &pluginIDs, folderIDs: &folderIDs)
    }

    var hasFolders: Bool {
        items.contains { item in
            if case .folder = item { return true }
            return false
        }
    }

    var pluginIDs: [String] { Self.pluginIDs(in: items) }

    func folder(withID id: UUID) -> Folder? {
        func find(in items: [Item]) -> Folder? {
            for case .folder(let folder) in items {
                if folder.id == id { return folder }
                if let nested = find(in: folder.children) { return nested }
            }
            return nil
        }
        return find(in: items)
    }

    func isVisible(hasAvailablePlugins: Bool) -> Bool {
        hasAvailablePlugins || hasFolders
    }

    @discardableResult
    mutating func createFolder(named name: String, in parentID: UUID? = nil) throws -> UUID {
        try appendFolder(to: parentID) { _ in name }
    }

    @discardableResult
    mutating func createFolder(defaultName: String, in parentID: UUID? = nil) throws -> UUID {
        try appendFolder(to: parentID) { siblings in
            var names = Self.folderNames(in: siblings)
            let baseName = defaultName.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.reserveFolderName(baseName, in: &names)
        }
    }

    mutating func renameFolder(_ id: UUID, to name: String) throws {
        try updateFolder(id) { folder, _ in
            var folder = folder
            folder.name = name
            return [.folder(folder)]
        }
    }

    mutating func deleteFolder(_ id: UUID) throws {
        try updateFolder(id) { folder, siblings in
            let siblingNames = Self.folderNames(in: siblings, excluding: id)
            // Reserve promoted folders' original names before assigning suffixes.
            var reservedNames = siblingNames.union(Self.folderNames(in: folder.children))
            return folder.children.map { item in
                guard case .folder(var child) = item, siblingNames.contains(child.name) else { return item }
                child.name = Self.reserveFolderName(child.name, in: &reservedNames)
                return .folder(child)
            }
        }
    }

    mutating func toggleFolder(_ id: UUID) throws {
        try updateFolder(id) { folder, _ in
            var folder = folder
            folder.isCollapsed.toggle()
            return [.folder(folder)]
        }
    }

    mutating func movePluginToRoot(_ id: String) throws -> Bool {
        var updatedItems = items
        guard Self.removePlugin(id, from: &updatedItems, insideFolder: false) else { return false }
        updatedItems.append(.plugin(id))
        self = try Self(items: updatedItems)
        return true
    }

    mutating func reorder(
        _ source: Item.ID,
        relativeTo anchor: Item.ID,
        position: InsertionPosition,
        in parentID: UUID?,
        unplacedRootPluginIDs: [String] = []
    ) throws -> Bool {
        guard source != anchor else { return false }
        var updatedItems = items
        if let parentID {
            var didReorder = false
            let found = Self.replaceFolderInTree(parentID, in: &updatedItems, expandingAncestors: false) { folder, _ in
                var folder = folder
                didReorder = Self.insert(source, relativeTo: anchor, position: position, in: &folder.children)
                return [.folder(folder)]
            }
            guard found && didReorder else { return false }
        } else {
            var placed = Set(pluginIDs)
            for id in unplacedRootPluginIDs where placed.insert(id).inserted {
                updatedItems.append(.plugin(id))
            }
            guard Self.insert(source, relativeTo: anchor, position: position, in: &updatedItems) else { return false }
        }
        self = try Self(items: updatedItems)
        return true
    }

    mutating func move(
        _ source: Item.ID,
        from sourceParentID: UUID?,
        to destination: MoveDestination,
        unplacedRootPluginIDs: [String] = []
    ) throws -> Bool {
        guard sourceParentID != destination.parentID else { return false }
        var updatedItems = items
        if destination.parentID == nil {
            var placed = Set(pluginIDs)
            for id in unplacedRootPluginIDs where placed.insert(id).inserted {
                updatedItems.append(.plugin(id))
            }
        } else if sourceParentID == nil, case .plugin(let id) = source,
                  unplacedRootPluginIDs.contains(id), !pluginIDs.contains(id) {
            updatedItems.append(.plugin(id))
        }

        var moved: Item?
        Self.editChildren(of: sourceParentID, in: &updatedItems) { siblings in
            guard let index = siblings.firstIndex(where: { $0.id == source }) else { return false }
            moved = siblings.remove(at: index)
            return true
        }
        guard let moved else { return false }

        let openParent: Bool
        switch destination {
        case .into: openParent = true
        case .beside: openParent = false
        }
        // Searching after detaching also excludes the source folder and its descendants as destinations.
        let inserted = Self.editChildren(of: destination.parentID, in: &updatedItems, openParent: openParent) { siblings in
            let index: Int
            switch destination {
            case .into:
                index = siblings.endIndex
            case .beside(let anchor, let position, _):
                guard let anchorIndex = siblings.firstIndex(where: { $0.id == anchor }) else { return false }
                index = position == .before ? anchorIndex : anchorIndex + 1
            }
            if case .folder(var folder) = moved {
                var names = Self.folderNames(in: siblings)
                folder.name = Self.reserveFolderName(folder.name, in: &names)
                siblings.insert(.folder(folder), at: index)
            } else {
                siblings.insert(moved, at: index)
            }
            return true
        }
        guard inserted else { return false }

        self = try Self(items: updatedItems)
        return true
    }

    @discardableResult
    private static func editChildren(
        of parentID: UUID?,
        in items: inout [Item],
        openParent: Bool = false,
        _ change: (inout [Item]) -> Bool
    ) -> Bool {
        guard let parentID else { return change(&items) }
        var changed = false
        _ = Self.replaceFolderInTree(parentID, in: &items, expandingAncestors: false) { folder, _ in
            var folder = folder
            changed = change(&folder.children)
            if changed && openParent { folder.isCollapsed = false }
            return [.folder(folder)]
        }
        return changed
    }

    private mutating func appendFolder(to parentID: UUID?, name: ([Item]) -> String) throws -> UUID {
        let id = UUID()
        if let parentID {
            try updateFolder(parentID, expandingAncestors: true, missingError: .parentFolderNotFound) { parent, _ in
                var parent = parent
                let folder = Folder(id: id, name: name(parent.children))
                parent.children.append(.folder(folder))
                parent.isCollapsed = false
                return [.folder(parent)]
            }
        } else {
            let folder = Folder(id: id, name: name(items))
            self = try Self(items: items + [.folder(folder)])
        }
        return id
    }

    private mutating func updateFolder(
        _ id: UUID,
        expandingAncestors: Bool = false,
        missingError: ValidationError = .folderNotFound,
        with replacement: (Folder, [Item]) -> [Item]
    ) throws {
        var updatedItems = items
        guard Self.replaceFolderInTree(id, in: &updatedItems, expandingAncestors: expandingAncestors, with: replacement) else {
            throw missingError
        }
        self = try Self(items: updatedItems)
    }

    private static func replaceFolderInTree(
        _ id: UUID,
        in items: inout [Item],
        expandingAncestors: Bool,
        with replacement: (Folder, [Item]) -> [Item]
    ) -> Bool {
        for index in items.indices {
            guard case .folder(var folder) = items[index] else { continue }
            if folder.id == id {
                let replacements = replacement(folder, items)
                items.replaceSubrange(index...index, with: replacements)
                return true
            }
            if replaceFolderInTree(id, in: &folder.children, expandingAncestors: expandingAncestors, with: replacement) {
                if expandingAncestors { folder.isCollapsed = false }
                items[index] = .folder(folder)
                return true
            }
        }
        return false
    }

    private static func removePlugin(_ id: String, from items: inout [Item], insideFolder: Bool) -> Bool {
        for index in items.indices {
            switch items[index] {
            case .plugin(let pluginID) where insideFolder && pluginID == id:
                items.remove(at: index)
                return true
            case .folder(var folder):
                if removePlugin(id, from: &folder.children, insideFolder: true) {
                    items[index] = .folder(folder)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    private static func insert(
        _ source: Item.ID,
        relativeTo anchor: Item.ID,
        position: InsertionPosition,
        in items: inout [Item]
    ) -> Bool {
        guard let sourceIndex = items.firstIndex(where: { $0.id == source }),
              let anchorIndex = items.firstIndex(where: { $0.id == anchor }) else { return false }
        let anchorAfterRemoval = sourceIndex < anchorIndex ? anchorIndex - 1 : anchorIndex
        let destination = position == .before ? anchorAfterRemoval : anchorAfterRemoval + 1
        guard sourceIndex != destination else { return false }

        let item = items.remove(at: sourceIndex)
        items.insert(item, at: destination)
        return true
    }

    private static func reserveFolderName(_ baseName: String, in names: inout Set<String>) -> String {
        var name = baseName
        var suffix = 1
        while !names.insert(name).inserted {
            name = "\(baseName)(\(suffix))"
            suffix += 1
        }
        return name
    }

    private static func folderNames(in items: [Item], excluding id: UUID? = nil) -> Set<String> {
        Set(items.compactMap { item in
            guard case .folder(let folder) = item, folder.id != id else { return nil }
            return folder.name
        })
    }

    private static func pluginIDs(in items: [Item]) -> [String] {
        items.flatMap { item in
            switch item {
            case .plugin(let id): [id]
            case .folder(let folder): pluginIDs(in: folder.children)
            }
        }
    }

    private static func validatedItems(
        _ items: [Item],
        depth: Int,
        pluginIDs: inout Set<String>,
        folderIDs: inout Set<UUID>
    ) throws -> [Item] {
        var folderNames = Set<String>()
        return try items.map { item in
            switch item {
            case .plugin(let id):
                guard pluginIDs.insert(id).inserted else { throw ValidationError.duplicatePluginID }
                return item
            case .folder(var folder):
                guard depth <= maximumFolderDepth else { throw ValidationError.folderDepthExceeded }
                guard folderIDs.insert(folder.id).inserted else { throw ValidationError.duplicateFolderID }
                folder.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !folder.name.isEmpty else { throw ValidationError.emptyFolderName }
                guard folderNames.insert(folder.name).inserted else { throw ValidationError.duplicateFolderName }
                folder.children = try validatedItems(
                    folder.children, depth: depth + 1, pluginIDs: &pluginIDs, folderIDs: &folderIDs
                )
                return .folder(folder)
            }
        }
    }
}

extension NectoPluginSidebarSection: Codable {
    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(items: container.decode([Item].self, forKey: .items))
    }
}
