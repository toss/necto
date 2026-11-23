//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// The arrangement of one sidebar section, independent of which plugins are available.
struct NectoPluginSidebarSection: Equatable, Sendable {
    enum Item: Codable, Equatable, Sendable {
        case plugin(String)
        case folder(Folder)
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

    mutating func toggleFolder(_ id: UUID) throws {
        try replaceFolder(id) { folder, _ in
            var folder = folder
            folder.isCollapsed.toggle()
            return [.folder(folder)]
        }
    }

    private mutating func appendFolder(to parentID: UUID?, name: ([Item]) -> String) throws -> UUID {
        let id = UUID()
        if let parentID {
            try replaceFolder(parentID, expandingAncestors: true, missingError: .parentFolderNotFound) { parent, _ in
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

    mutating func renameFolder(_ id: UUID, to name: String) throws {
        try replaceFolder(id) { folder, _ in
            var folder = folder
            folder.name = name
            return [.folder(folder)]
        }
    }

    mutating func deleteFolder(_ id: UUID) throws {
        try replaceFolder(id) { folder, siblings in
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

    private mutating func replaceFolder(
        _ id: UUID,
        expandingAncestors: Bool = false,
        missingError: ValidationError = .folderNotFound,
        with replacement: (Folder, [Item]) -> [Item]
    ) throws {
        var updatedItems = items
        guard Self.replaceFolder(id, in: &updatedItems, expandingAncestors: expandingAncestors, with: replacement) else {
            throw missingError
        }
        self = try Self(items: updatedItems)
    }

    private static func replaceFolder(
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
            if replaceFolder(id, in: &folder.children, expandingAncestors: expandingAncestors, with: replacement) {
                if expandingAncestors { folder.isCollapsed = false }
                items[index] = .folder(folder)
                return true
            }
        }
        return false
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
