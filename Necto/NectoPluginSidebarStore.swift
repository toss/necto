//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

@MainActor
struct NectoPluginSidebarStore {
    enum Kind: String {
        case desktop
        case device

        var sectionKey: String {
            switch self {
            case .desktop: "desktopPluginSidebarSection"
            case .device: "devicePluginSidebarSection"
            }
        }

        var legacyOrderKey: String {
            switch self {
            case .desktop: "pluginOrder"
            case .device: "devicePluginOrder"
            }
        }
    }

    enum StorageError: Error, Equatable {
        case invalidSavedSection
        case sectionContainsFolders
    }

    let defaults: UserDefaults

    func load(_ kind: Kind) throws -> NectoPluginSidebarSection {
        if let saved = try savedSection(for: kind) { return saved }

        let legacyOrder = defaults.stringArray(forKey: kind.legacyOrderKey) ?? []
        let ids = Self.uniqueIDs(legacyOrder)
        let migrated = try NectoPluginSidebarSection(items: ids.map { .plugin($0) })
        try write(migrated, for: kind)
        return migrated
    }

    func save(_ section: NectoPluginSidebarSection, for kind: Kind) throws {
        // Read first so a corrupt or unsupported saved value stays available for recovery.
        _ = try savedSection(for: kind)
        try write(section, for: kind)
    }

    func pluginOrder(for kind: Kind) throws -> [String] {
        Self.pluginIDs(in: try load(kind).items)
    }

    /// Keeps the old flat drag behavior until the sidebar supports folder-aware reordering.
    func saveFlatOrder(_ ids: [String], for kind: Kind) throws -> [String] {
        let previousIDs = try load(kind).items.map { item in
            guard case .plugin(let id) = item else { throw StorageError.sectionContainsFolders }
            return id
        }
        // Plugin availability can change between reorders. Keep unlisted IDs in their relative order.
        let order = Self.uniqueIDs(ids + previousIDs)
        let updated = try NectoPluginSidebarSection(items: order.map { .plugin($0) })
        try write(updated, for: kind)
        return order
    }

    private func savedSection(for kind: Kind) throws -> NectoPluginSidebarSection? {
        guard let value = defaults.object(forKey: kind.sectionKey) else { return nil }
        guard let data = value as? Data,
              let section = try? JSONDecoder().decode(NectoPluginSidebarSection.self, from: data) else {
            throw StorageError.invalidSavedSection
        }
        return section
    }

    private func write(_ section: NectoPluginSidebarSection, for kind: Kind) throws {
        let data = try JSONEncoder().encode(section)
        defaults.set(data, forKey: kind.sectionKey)
    }

    private static func pluginIDs(in items: [NectoPluginSidebarSection.Item]) -> [String] {
        items.flatMap { item in
            switch item {
            case .plugin(let id): [id]
            case .folder(let folder): pluginIDs(in: folder.children)
            }
        }
    }

    private static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
