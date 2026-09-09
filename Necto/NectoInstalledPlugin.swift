//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoMacService
import Foundation

struct NectoInstalledPlugin: Identifiable, Sendable {
    /// Where the plugin came from, which is what decides whether it can be removed.
    enum Source: Sendable, Equatable {
        /// Lives in the plugins folder and can be taken back out of it.
        case installed
        /// Carried in by a connected app and cached on this Mac. It cannot be removed
        /// here, because the app owns it: it goes away when the app stops offering it.
        case device(appName: String, appBundleID: String)
    }

    let manifest: NectoPluginManifest
    /// The root of the plugin's assets. WebView read access is limited to it.
    let rootURL: URL
    let source: Source
    /// Serve the bytes that were checked, even if the folder changes afterwards.
    let archive: NectoPanelArchive
    let contentIdentity: String
    var installation: NectoLocalPluginInstallation?

    var principal: NectoPluginPrincipal? {
        switch source {
        case .installed: installation?.principal
        case let .device(_, appBundleID):
            NectoPluginPrincipal(pluginID: id, sourceIdentity: "device:\(appBundleID)")
        }
    }

    var id: String { manifest.id }

    var runsInBackground: Bool {
        source == .installed && !manifest.requiresTarget
            && manifest.operations.contains { NectoBackgroundProvider().descriptor.mismatch(with: $0) == nil }
    }
}

enum NectoPluginLoaderError: Error, CustomStringConvertible {
    case manifestNotFound(URL)

    var description: String {
        switch self {
        case let .manifestNotFound(url): "No manifest.json at \(url.path)"
        }
    }
}

enum NectoPluginLoader {
    static func load(from directory: URL, source: NectoInstalledPlugin.Source = .installed) throws -> NectoInstalledPlugin {
        let archive = try NectoPanelArchive.read(directory: directory)
        guard let data = archive.files.first(where: { $0.path == "manifest.json" })?.data else {
            throw NectoPluginLoaderError.manifestNotFound(directory.appendingPathComponent("manifest.json"))
        }
        let manifest = try JSONDecoder().decode(NectoPluginManifest.self, from: data)
        try manifest.validate()

        return NectoInstalledPlugin(
            manifest: manifest,
            rootURL: directory,
            source: source,
            archive: archive,
            contentIdentity: archive.contentHash
        )
    }

    /// What a scan found, including what it could not read.
    ///
    /// Failures come back rather than being logged, because a plugin that vanishes from
    /// the sidebar with only a line in a console nobody is watching is the hardest kind
    /// to debug — and this loader did exactly that.
    struct Scan {
        var plugins: [NectoInstalledPlugin] = []
        /// Folder name to the reason it was skipped.
        var failures: [String: String] = [:]
    }

    /// One invalid plugin is skipped rather than failing the whole load.
    static func loadAll(in directory: URL, source: NectoInstalledPlugin.Source = .installed) -> Scan {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        var scan = Scan()

        for entry in entries {
            guard !entry.lastPathComponent.hasPrefix(".necto-install-"),
                  !entry.lastPathComponent.hasPrefix(".necto-backup-") else { continue }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            do {
                scan.plugins.append(try load(from: entry, source: source))
            } catch {
                scan.failures[entry.lastPathComponent] = String(describing: error)
            }
        }

        scan.plugins.sort { $0.manifest.name < $1.manifest.name }
        return scan
    }
}
