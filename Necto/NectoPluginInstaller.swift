//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoMacService
import Foundation

/// Brings a plugin as far as the approval screen, and no further.
///
/// Necto never builds a plugin. What is installed is what the author published, so a
/// source checkout is not an input: the only shapes accepted are a folder that already
/// contains `manifest.json` and a zip of one.
enum NectoPluginInstaller {
    /// A plugin unpacked somewhere temporary, read and validated, waiting for an answer.
    struct Staged {
        let manifest: NectoPluginManifest
        let archive: NectoPanelArchive
        /// Where it came from, shown on the approval screen so the answer is informed.
        let origin: String
        let previous: NectoInstalledPlugin?
        var replaces: String? { previous?.manifest.name }
        var keepsPermissions: Bool { previous?.installation != nil }
    }

    enum Failure: LocalizedError {
        case noManifest
        case unreadableManifest(String)
        case duplicateID(String)
        case wrongID(expected: String, actual: String)
        case unpackFailed(String)
        case severalPlugins([String])
        case deviceBound(String)

        var errorDescription: String? {
            switch self {
            case .noManifest:
                NectoL10n.text("No manifest.json was found in what was downloaded")
            case let .unreadableManifest(detail):
                NectoL10n.format("manifest.json could not be read: %@", detail)
            case let .duplicateID(id):
                NectoL10n.format("Another plugin already uses the id '%@'", id)
            case let .wrongID(expected, actual):
                NectoL10n.format("Expected plugin id '%@', but the selected files use '%@'.", expected, actual)
            case let .unpackFailed(detail):
                NectoL10n.format("Could not unpack the archive: %@", detail)
            case let .severalPlugins(names):
                NectoL10n.format(
                    "This holds several plugins (%@). Install them one at a time, or give Necto the repository they were published from.",
                    names.joined(separator: ", ")
                )
            case let .deviceBound(name):
                NectoL10n.format(
                    "This plugin binds to '%@', which a connected app answers. A plugin that needs the app rides in the app: add its Swift package there, and it appears here on its own.",
                    name
                )
            }
        }
    }

    // MARK: Staging

    /// `describedAs` names a source the file path cannot: an archive fetched from a
    /// repository lands in a temporary directory, and a person asked to approve it
    /// deserves to be told the repository rather than the directory.
    static func stage(
        from source: URL,
        installed: [NectoInstalledPlugin],
        expectedPluginID: String? = nil,
        describedAs describedOrigin: String? = nil
    ) async throws -> Staged {
        try Task.checkCancellation()
        let unpacked = try await copyIn(source)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try Task.checkCancellation()

        let roots = NectoPluginArchiveLayout.roots(in: unpacked)
        guard let root = roots.first else { throw Failure.noManifest }
        guard roots.count == 1 else {
            throw Failure.severalPlugins(roots.map(\.lastPathComponent))
        }

        let plugin: NectoInstalledPlugin
        do {
            plugin = try NectoPluginLoader.load(from: root)
        } catch {
            throw Failure.unreadableManifest(String(describing: error))
        }
        let manifest = plugin.manifest
        if let expectedPluginID, manifest.id != expectedPluginID {
            throw Failure.wrongID(expected: expectedPluginID, actual: manifest.id)
        }
        let existing = installed.filter { $0.id == manifest.id }
        guard existing.count <= 1 else { throw Failure.duplicateID(manifest.id) }

        // What is added here lives on this Mac and answers from this Mac. Anything
        // that needs the app is the app's to carry, and letting it install here would
        // bring back the two-place adoption this split exists to end.
        if let bound = manifest.operations.first(where: { $0.binding.type == .device }) {
            throw Failure.deviceBound(bound.binding.name)
        }

        return Staged(
            manifest: manifest,
            archive: plugin.archive,
            origin: describedOrigin ?? source.path,
            previous: existing.first
        )
    }

    /// Only once the user has said yes. Until then nothing has been written to the
    /// plugins folder, so cancelling leaves no trace to clean up.
    static func commit(_ staged: Staged, into directory: URL) throws -> URL {
        let destination = staged.previous?.rootURL
            ?? directory.appending(path: staged.manifest.id, directoryHint: .isDirectory)
        guard destination.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else {
            throw NectoPanelArchiveError.unsafePath(destination.path)
        }
        try NectoLocalPluginFiles.install(
            staged.archive,
            at: destination,
            replacingContentHash: staged.previous?.contentIdentity
        )
        return destination
    }

    private static func copyIn(_ url: URL) async throws -> URL {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard !isDirectory else {
            let staging = try makeStagingDirectory()
            let copy = staging.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
            return staging
        }
        return try await unzip(url)
    }

    private static func unzip(_ archive: URL) async throws -> URL {
        let staging = try makeStagingDirectory()
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: staging) } }

        do {
            try await NectoPluginArchiveLayout.extractZIP(at: archive, into: staging)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unpackFailed(error.localizedDescription)
        }

        succeeded = true
        return staging
    }

    private static func makeStagingDirectory() throws -> URL {
        let staging = URL(filePath: NSTemporaryDirectory())
            .appending(path: "necto-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }
}
