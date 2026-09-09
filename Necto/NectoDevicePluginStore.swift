//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// The panels connected apps carry, cached on disk.
///
/// Content hashes keep different app builds apart. Cache contents are verified
/// before reuse; legacy SDK stamps always require a fresh fetch.
@MainActor
final class NectoDevicePluginStore {
    /// `~/Library/Application Support/Necto/DevicePlugins`, created on first use.
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appending(path: "Necto/DevicePlugins", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The plugin for this registration, fetching only when the cache holds no copy
    /// of these exact bytes.
    func plugin(
        pluginID: String,
        stamp: NectoPanelStamp,
        appName: String,
        appBundleID: String,
        fetch: () async throws -> NectoPanelArchive
    ) async throws -> NectoInstalledPlugin {
        let advertised = stamp.contentHash ?? stamp.hash
        guard pluginID != ".", pluginID != "..",
              pluginID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              advertised.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw NectoDevicePluginError.hashMismatch(pluginID)
        }
        var root = Self.directory
            .appending(path: pluginID, directoryHint: .isDirectory)
            .appending(path: advertised, directoryHint: .isDirectory)

        let cached = stamp.contentHash.flatMap { expected in
            (try? NectoPanelArchive.read(directory: root)).flatMap { $0.contentHash == expected ? $0 : nil }
        }
        if cached == nil {
            let archive = try await fetch()
            // The stamp travelled with the registration, the bytes travelled on their
            // own; nothing that fails this check is written anywhere.
            guard stamp.contentHash.map({ archive.contentHash == $0 }) ?? (archive.legacyContentHash == stamp.hash) else {
                throw NectoDevicePluginError.hashMismatch(pluginID)
            }
            // Old SDK stamps cannot safely identify cached contents. Fetch each
            // registration, then store under the newly computed unambiguous hash.
            root = Self.directory.appending(path: pluginID).appending(path: archive.contentHash)
            let manager = FileManager.default
            let parent = root.deletingLastPathComponent()
            let staging = parent.appending(path: ".necto-install-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: staging) }
            try archive.write(into: staging)
            let staged = try NectoPluginLoader.load(from: staging)
            guard staged.manifest.id == pluginID else {
                throw NectoDevicePluginError.wrongID(manifest: staged.manifest.id, registered: pluginID)
            }
            guard staged.contentIdentity == archive.contentHash else {
                throw NectoDevicePluginError.hashMismatch(pluginID)
            }
            if (try? manager.attributesOfItem(atPath: root.path)) != nil {
                let backupName = ".necto-backup-\(UUID().uuidString)"
                let backup = parent.appending(path: backupName)
                do {
                    _ = try manager.replaceItemAt(
                        root, withItemAt: staging, backupItemName: backupName,
                        options: .withoutDeletingBackupItem
                    )
                } catch {
                    if !manager.fileExists(atPath: root.path), manager.fileExists(atPath: backup.path) {
                        try? manager.moveItem(at: backup, to: root)
                    }
                    throw error
                }
                try? manager.removeItem(at: backup)
            } else {
                try manager.moveItem(at: staging, to: root)
            }
        }

        let plugin = try NectoPluginLoader.load(
            from: root,
            source: .device(appName: appName, appBundleID: appBundleID)
        )
        // The registration named the plugin; the manifest inside must be the same one,
        // or an app could smuggle one plugin in under another's approval.
        guard plugin.manifest.id == pluginID else {
            throw NectoDevicePluginError.wrongID(manifest: plugin.manifest.id, registered: pluginID)
        }
        guard plugin.contentIdentity == root.lastPathComponent else {
            throw NectoDevicePluginError.hashMismatch(pluginID)
        }
        return plugin
    }
}

enum NectoDevicePluginError: Error, CustomStringConvertible {
    case hashMismatch(String)
    case wrongID(manifest: String, registered: String)

    var description: String {
        switch self {
        case let .hashMismatch(pluginID):
            "The panel of '\(pluginID)' did not match the hash its registration promised"
        case let .wrongID(manifest, registered):
            "The panel's manifest says '\(manifest)', the registration said '\(registered)'"
        }
    }
}
