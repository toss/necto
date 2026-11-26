//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

@MainActor
struct NectoPluginSidebarStore {
    enum Kind: String, CaseIterable, Sendable {
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

    private static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
