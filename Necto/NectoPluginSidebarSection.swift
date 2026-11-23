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

        init(id: UUID = UUID(), name: String, children: [Item] = []) {
            self.id = id
            self.name = name
            self.children = children
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

    private static let maximumFolderDepth = 3

    private(set) var items: [Item]

    init(items: [Item] = []) throws {
        var pluginIDs = Set<String>()
        var folderIDs = Set<UUID>()
        self.items = try Self.validatedItems(items, depth: 1, pluginIDs: &pluginIDs, folderIDs: &folderIDs)
    }

    @discardableResult
    mutating func createFolder(named name: String, in parentID: UUID? = nil) throws -> UUID {
        let folder = Folder(name: name)
        if let parentID {
            try replaceFolder(parentID, missingError: .parentFolderNotFound) { parent, _ in
                var parent = parent
                parent.children.append(.folder(folder))
                return [.folder(parent)]
            }
        } else {
            self = try Self(items: items + [.folder(folder)])
        }
        return folder.id
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
            let siblingNames = Set(siblings.compactMap { item -> String? in
                guard case .folder(let sibling) = item, sibling.id != id else { return nil }
                return sibling.name
            })
            // Reserve promoted folders' original names before assigning suffixes.
            var reservedNames = siblingNames
            for case .folder(let child) in folder.children {
                reservedNames.insert(child.name)
            }
            return folder.children.map { item in
                guard case .folder(var child) = item, siblingNames.contains(child.name) else { return item }
                let baseName = child.name
                var suffix = 1
                repeat {
                    child.name = "\(baseName)(\(suffix))"
                    suffix += 1
                } while !reservedNames.insert(child.name).inserted
                return .folder(child)
            }
        }
    }

    private mutating func replaceFolder(
        _ id: UUID,
        missingError: ValidationError = .folderNotFound,
        with replacement: (Folder, [Item]) -> [Item]
    ) throws {
        var updatedItems = items
        guard Self.replaceFolder(id, in: &updatedItems, with: replacement) else { throw missingError }
        self = try Self(items: updatedItems)
    }

    private static func replaceFolder(
        _ id: UUID,
        in items: inout [Item],
        with replacement: (Folder, [Item]) -> [Item]
    ) -> Bool {
        for index in items.indices {
            guard case .folder(var folder) = items[index] else { continue }
            if folder.id == id {
                let replacements = replacement(folder, items)
                items.replaceSubrange(index...index, with: replacements)
                return true
            }
            if replaceFolder(id, in: &folder.children, with: replacement) {
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
