//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoModel
import NectoMacService
import Foundation
import Observation

/// Keeps Necto current from its own releases.
@MainActor
@Observable
final class NectoUpdater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// Newer release, and this copy can replace itself.
        case available(NectoSemanticVersion)
        /// Newer release, but Necto is not running from /Applications — a dev build
        /// or a stray copy. It should not overwrite whatever it is running from.
        case outside(NectoSemanticVersion)
        /// One human-readable step: Downloading…, Verifying…, Installing…
        case working(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private let current: NectoSemanticVersion
    private var availableRelease: NectoAppRelease?
    private var isChecking = false

    init(current: NectoSemanticVersion) {
        self.current = current
    }

    /// Looks up the latest release. Quiet failures stay quiet: an update check that
    /// cannot reach the network is not news worth a badge.
    func check(quietly: Bool = false) async {
        if case .working = phase { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        await performCheck(quietly: quietly)
    }

    private func performCheck(quietly: Bool) async {
        if !quietly { phase = .checking }
        do {
            let release = try await NectoAppRelease.latest()
            if case .working = phase { return }
            let latest = release.version
            availableRelease = release
            if latest > current {
                phase = Self.isInstalled ? .available(latest) : .outside(latest)
            } else {
                phase = .upToDate
            }
        } catch {
            if case .working = phase { return }
            phase = quietly ? .idle : .failed(Self.message(of: error))
        }
    }

    /// Stages a verified update, then lets a helper install it after this app exits.
    func update() async {
        guard case let .available(version) = phase, let release = availableRelease,
              release.version == version else { return }

        let target = Bundle.main.bundleURL
        let workspace = target.deletingLastPathComponent()
            .appending(path: ".necto-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        var mountedImage: URL?
        var handedOff = false
        defer {
            if !handedOff && mountedImage == nil {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        do {
            let helper = target.appending(path: "Contents/MacOS/necto-cli")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: helper.path])
            }
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let handoffExecutable = workspace.appending(path: "finish-update")
            try FileManager.default.copyItem(at: helper, to: handoffExecutable)

            phase = .working(NectoL10n.text("Downloading…"))
            let image = try await release.downloadImage(into: workspace)

            phase = .working(NectoL10n.text("Verifying…"))
            try await release.verifyImageChecksum(at: image)

            let mountpoint = workspace.appending(path: "mnt", directoryHint: .isDirectory)
            mountedImage = mountpoint
            _ = try await Self.run("/usr/bin/hdiutil", [
                "attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mountpoint.path,
            ])
            let sourceApp = mountpoint.appending(path: "Necto.app", directoryHint: .isDirectory)
            let sourceContents = sourceApp.appending(path: "Contents", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceContents.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw Failure(NectoL10n.text("The dmg contains no app"))
            }
            try await NectoUpdateValidation.verify(candidate: sourceApp, installed: target, expectedVersion: version)
            phase = .working(NectoL10n.text("Installing…"))
            // Stage on the same volume, without creating a second .app for Launch Services.
            let stagedContents = workspace.appending(path: "Contents", directoryHint: .isDirectory)
            _ = try await Self.run("/usr/bin/ditto", [sourceContents.path, stagedContents.path])
            _ = try await Self.run("/usr/bin/hdiutil", ["detach", mountpoint.path, "-quiet"])
            mountedImage = nil

            phase = .working(NectoL10n.text("Relaunching…"))
            let log = workspace.appending(path: "install.log")
            try Data().write(to: log)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = handoffExecutable
            process.arguments = [
                "_finish-update", String(ProcessInfo.processInfo.processIdentifier), target.path, workspace.path,
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                guard status != 0 else { return }
                Task { @MainActor [weak self] in
                    let details = (try? String(contentsOf: log, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self?.phase = .failed(details.isEmpty ? "necto-cli exited \(status): \(log.path)" : details)
                }
            }
            try Task.checkCancellation()
            try process.run()
            // The helper owns cleanup and must observe our exit before replacing or opening anything.
            handedOff = true
            NSApplication.shared.terminate(nil)
        } catch {
            if let mountpoint = mountedImage {
                do {
                    // Cleanup must still run when the update task was cancelled.
                    _ = try await Task { @MainActor in
                        try await Self.run("/usr/bin/hdiutil", ["detach", mountpoint.path, "-quiet"])
                    }.value
                    mountedImage = nil
                } catch {
                    // Keep the workspace if its image could not be detached.
                }
            }
            phase = .failed(Self.message(of: error))
        }
    }

    /// For the copy that cannot replace itself: take the person where the release is.
    func showReleases() {
        NSWorkspace.shared.open(NectoAppRelease.pageURL)
    }

    private static var isInstalled: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    private struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private static func message(of error: any Error) -> String {
        if let failure = error as? NectoAppRelease.Failure {
            switch failure {
            case .invalidRelease: return NectoL10n.text("The release does not provide valid app assets.")
            case .checksumMismatch: return NectoL10n.text("The download did not match its published hash. Nothing was installed.")
            case let .downloadFailed(status): return NectoL10n.format("The update download failed (HTTP %d).", status)
            case .tooLarge: return NectoL10n.text("The update download exceeded its size limit.")
            }
        }
        if error is NectoUpdateValidation.Failure {
            return NectoL10n.text("The update's integrity, app ID or version could not be verified. Nothing was installed.")
        }
        return (error as? Failure)?.reason ?? String(describing: error)
    }

    private static func run(_ path: String, _ arguments: [String]) async throws -> Data {
        let output = try await NectoProcessRunner.run(path, arguments: arguments)
        guard output.exitCode == 0 else {
            let reason = String(decoding: output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(reason.isEmpty ? "\(path) exited \(output.exitCode)" : reason)
        }
        return output.stdout
    }
}
