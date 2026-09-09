//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

public enum NectoLocalPluginFiles {
    /// Installs only the approved snapshot. An existing destination must still match
    /// the version shown in the approval sheet; a failed replacement keeps a backup.
    public static func install(
        _ archive: NectoPanelArchive,
        at destination: URL,
        replacingContentHash: String?
    ) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".necto-install-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try archive.write(into: staging)

        if let replacingContentHash {
            let current = try NectoPanelArchive.read(directory: destination)
            guard current.contentHash == replacingContentHash else { throw Failure.changedSinceReview }
            let backupName = ".necto-backup-\(UUID().uuidString)"
            let backup = parent.appending(path: backupName)
            do {
                _ = try manager.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: backupName,
                    options: .withoutDeletingBackupItem
                )
            } catch {
                if !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: backup.path) {
                    try? manager.moveItem(at: backup, to: destination)
                }
                throw error
            }
            try? manager.removeItem(at: backup)
        } else {
            // moveItem refuses an existing destination, including one added during review.
            try manager.moveItem(at: staging, to: destination)
        }
    }

    public enum Failure: Error {
        case changedSinceReview
    }
}
