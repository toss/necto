//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Darwin
import Foundation

enum UpdateFinisher {
    enum Failure: LocalizedError, Equatable {
        case invalidArguments
        case appDidNotExit
        case couldNotBackUp
        case couldNotInstall
        case couldNotLaunch
        case rollbackFailed

        var errorDescription: String? {
            switch self {
            case .invalidArguments:
                "The update handoff arguments are invalid."
            case .appDidNotExit:
                "Necto did not exit within 30 seconds. Nothing was installed."
            case .couldNotBackUp:
                "The existing app Contents could not be moved."
            case .couldNotInstall:
                "The update could not be installed. The previous Contents were restored."
            case .couldNotLaunch:
                "The update could not be opened. The previous Contents were restored."
            case .rollbackFailed:
                "The previous Contents could not be restored. Keep the update workspace for recovery."
            }
        }
    }

    struct Driver {
        var isProcessRunning: (pid_t) -> Bool
        var pause: () throws -> Void
        var move: (URL, URL) throws -> Void
        var remove: (URL) throws -> Void
        var exists: (URL) -> Bool
        var launch: (URL) throws -> Void

        static var live: Self {
            Self(
                isProcessRunning: { processID in
                    kill(processID, 0) == 0 || errno == EPERM
                },
                pause: { Thread.sleep(forTimeInterval: 0.1) },
                move: { try FileManager.default.moveItem(at: $0, to: $1) },
                remove: { try FileManager.default.removeItem(at: $0) },
                exists: { FileManager.default.fileExists(atPath: $0.path) },
                launch: { url in
                    let process = Process()
                    process.executableURL = URL(filePath: "/usr/bin/open")
                    process.arguments = [url.path]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw Failure.couldNotLaunch }
                }
            )
        }
    }

    static func finish(
        oldPID: pid_t,
        target: URL,
        workspace: URL,
        attempts: Int = 300,
        driver: Driver = .live
    ) throws {
        let target = target.standardizedFileURL
        let workspace = workspace.standardizedFileURL
        let targetContents = target.appending(path: "Contents", directoryHint: .isDirectory)
        let stagedContents = workspace.appending(path: "Contents", directoryHint: .isDirectory)
        let previousContents = workspace.appending(path: "PreviousContents", directoryHint: .isDirectory)
        guard oldPID > 1,
              attempts > 0,
              target.isFileURL,
              target.path.hasPrefix("/"),
              target.pathExtension == "app",
              workspace.lastPathComponent.hasPrefix(".necto-update-"),
              target.deletingLastPathComponent() == workspace.deletingLastPathComponent(),
              driver.exists(targetContents),
              driver.exists(stagedContents),
              !driver.exists(previousContents)
        else { throw Failure.invalidArguments }

        for attempt in 0..<attempts {
            if !driver.isProcessRunning(oldPID) { break }
            guard attempt < attempts - 1 else { throw Failure.appDidNotExit }
            try driver.pause()
        }

        do {
            try driver.move(targetContents, previousContents)
        } catch {
            try? driver.launch(target)
            throw Failure.couldNotBackUp
        }
        do {
            try driver.move(stagedContents, targetContents)
        } catch {
            do {
                try driver.move(previousContents, targetContents)
            } catch {
                throw Failure.rollbackFailed
            }
            try? driver.launch(target)
            throw Failure.couldNotInstall
        }
        do {
            try driver.launch(target)
        } catch {
            do {
                try driver.move(targetContents, stagedContents)
                try driver.move(previousContents, targetContents)
            } catch {
                throw Failure.rollbackFailed
            }
            try? driver.launch(target)
            throw Failure.couldNotLaunch
        }
        try? driver.remove(workspace)
    }
}
