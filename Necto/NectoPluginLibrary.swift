//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoModel
import NectoMacService
import Foundation

/// Where installed plugins live, and which of them are switched on.
///
/// A plugin is a folder with a manifest, the same shape whether it shipped with Necto or
/// was dropped in afterwards. New or modified files need approval before loading.
@MainActor
struct NectoPluginLibrary {
    private static let disabledKey = "disabledPluginIDs"
    private static let orderKey = "pluginOrder"
    private static let grantsKey = "pluginGrants"
    private static let deviceOrderKey = "devicePluginOrder"
    private static let shellPolicyKey = "shellPolicy"
    private static let installationsKey = "localPluginInstallations"

    static var installations: [String: NectoLocalPluginInstallation] {
        get {
            guard let data = UserDefaults.standard.data(forKey: installationsKey),
                  let records = try? JSONDecoder().decode([String: NectoLocalPluginInstallation].self, from: data)
            else { return [:] }
            return records
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: installationsKey)
        }
    }

    /// `~/Library/Application Support/Necto/Plugins`, created on first use.
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appending(path: "Necto/Plugins", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func loadInstalled() -> NectoPluginLoader.Scan {
        var scan = NectoPluginLoader.loadAll(in: directory, source: .installed)
        let records = installations
        scan.plugins = scan.plugins.map { plugin in
            var plugin = plugin
            if let record = records[plugin.id], record.matches(pluginID: plugin.id, directoryPath: plugin.rootURL.path) {
                plugin.installation = record
            }
            return plugin
        }
        return scan
    }

    // MARK: Enablement

    /// Installed and enabled are separate. Turning a plugin off is how you find out
    /// whether it is the one misbehaving, without losing it or its settings.
    static var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    static func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    /// What the user agreed to, per plugin. Written when an install is approved and
    /// read on every launch, so an approval is a decision rather than a formality that
    /// the manifest answers for itself.
    static var grants: NectoPluginGrants {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: grantsKey) as? [String: [String]]
            return NectoPluginGrants(stored: stored ?? [:])
        }
        set { UserDefaults.standard.set(newValue.stored, forKey: grantsKey) }
    }

    static var shellPolicy: NectoShellPolicySnapshot {
        get {
            guard let data = UserDefaults.standard.data(forKey: shellPolicyKey),
                  let value = try? JSONDecoder().decode(NectoShellPolicySnapshot.self, from: data)
            else { return NectoShellPolicySnapshot() }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: shellPolicyKey)
        }
    }

    static func setEnabled(_ id: String, _ enabled: Bool) {
        var ids = disabledIDs
        if enabled { ids.remove(id) } else { ids.insert(id) }
        disabledIDs = ids
    }


    // MARK: Order

    /// The order the user dragged them into. Ids the list does not mention sort after
    /// it by name, so a newly installed plugin appears at the end rather than jumping
    /// into the middle of an arrangement someone chose.
    static var order: [String] {
        get { UserDefaults.standard.stringArray(forKey: orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: orderKey) }
    }

    /// The arrangement of the Device Plugins section, kept apart from the desktop
    /// list so the two `onMove` writers never clobber each other.
    static var deviceOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: deviceOrderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: deviceOrderKey) }
    }

    static func sorted(_ plugins: [NectoInstalledPlugin], by order: [String]? = nil) -> [NectoInstalledPlugin] {
        let order = order ?? self.order
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })

        return plugins.sorted { first, second in
            switch (rank[first.id], rank[second.id]) {
            case let (first?, second?): first < second
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): first.manifest.name < second.manifest.name
            }
        }
    }

    // MARK: Removing

    /// To the trash rather than deleted outright: a plugin can hold hours of someone's
    /// configuration, and the folder is the only copy on this Mac.
    static func remove(_ plugin: NectoInstalledPlugin) throws {
        guard plugin.source == .installed else { return }
        try FileManager.default.trashItem(at: plugin.rootURL, resultingItemURL: nil)

        // The grant outlives the files unless it is cleared here, and a reinstall would
        // silently inherit permissions the user last approved for a different version.
        var ids = disabledIDs
        ids.remove(plugin.id)
        disabledIDs = ids
    }

    static func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
