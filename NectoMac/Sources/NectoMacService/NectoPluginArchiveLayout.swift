//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// Finds plugin roots in folders and release archives.
public enum NectoPluginArchiveLayout {
    /// Ignores Finder metadata and follows single-directory archive wrappers.
    public static func roots(in directory: URL, using manager: FileManager = .default) -> [URL] {
        roots(in: directory, using: manager, wrappersLeft: maximumWrappers)
    }

    /// Bounds directory traversal even for deeply nested archives.
    private static let maximumWrappers = 2

    /// The caller owns the staging directory and removes it on failure or cancellation.
    public static func extractZIP(at archive: URL, into staging: URL) async throws {
        let output = try await NectoProcessRunner.run(
            "/usr/bin/ditto", arguments: ["-x", "-k", archive.path, staging.path],
            timeoutMilliseconds: 30_000, maximumOutputBytes: 1_048_576)
        guard output.exitCode == 0 else {
            let detail = String(decoding: output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: detail.isEmpty ? "ditto exited \(output.exitCode)" : detail
            ])
        }
    }

    private static func roots(in directory: URL, using manager: FileManager, wrappersLeft: Int) -> [URL] {
        if manager.fileExists(atPath: directory.appending(path: "manifest.json").path) {
            return [directory]
        }

        let entries = contents(of: directory, using: manager)
        let found = entries
            .filter { manager.fileExists(atPath: $0.appending(path: "manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !found.isEmpty { return found }

        // Do not mistake nested assets for additional plugins.
        guard entries.count == 1, wrappersLeft > 0 else { return [] }
        return roots(in: entries[0], using: manager, wrappersLeft: wrappersLeft - 1)
    }

    private static func contents(of directory: URL, using manager: FileManager) -> [URL] {
        let entries = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        return entries.filter { entry in
            guard entry.lastPathComponent != "__MACOSX" else { return false }
            return (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
