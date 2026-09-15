//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import Testing

@Suite("CLI installation", .timeLimit(.minutes(1)))
@MainActor
struct NectoCLIInstallerTests {
    private struct Fixture {
        let root: URL
        let tool: URL
        let directory: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "necto-cli-install-\(UUID())")
            directory = root.appending(path: "local/bin")
            tool = root.appending(path: "Necto 'quoted' \"app\" $(touch SENTINEL) `touch BACKTICK`\n한국어/necto-cli")
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        func prepareDirectory() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func link(_ name: String) -> URL { directory.appending(path: name) }

        func execute(_ command: String) async throws {
            let output = try await NectoProcessRunner.run("/bin/sh", arguments: ["-c", command], directory: root)
            guard output.exitCode == 0 else {
                throw NSError(domain: "CLIInstallationTest", code: Int(output.exitCode), userInfo: [
                    NSLocalizedDescriptionKey: String(decoding: output.stderr, as: UTF8.self),
                ])
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Creates both links, preserves quoted paths, and skips authorization when already installed")
    func installAndReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var approvals = 0
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { command in
            approvals += 1
            try await fixture.execute(command)
        }
        #expect(installer.isAvailable)
        #expect(!installer.isInstalled)
        await installer.install()
        #expect(installer.error == nil)
        #expect(installer.isInstalled)
        #expect(!installer.isInstalling)
        for name in ["necto", "necto-cli"] {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link(name).path) == fixture.tool.path)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "SENTINEL").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "BACKTICK").path))
        await installer.install()
        #expect(approvals == 1)
        let reopened = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { _ in
            Issue.record("Existing links must not ask for authorization")
        }
        #expect(reopened.isInstalled)
        await reopened.install()
        try FileManager.default.removeItem(at: fixture.link("necto-cli"))
        reopened.refresh()
        #expect(!reopened.isInstalled)
    }

    @Test("Repairs a missing alias without replacing the existing link")
    func missingAlias() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareDirectory()
        try FileManager.default.createSymbolicLink(at: fixture.link("necto"), withDestinationURL: fixture.tool)
        let before = try FileManager.default.attributesOfItem(atPath: fixture.link("necto").path)[.systemFileNumber] as? NSNumber
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory, authorize: fixture.execute)
        await installer.install()
        #expect(installer.isInstalled)
        let after = try FileManager.default.attributesOfItem(atPath: fixture.link("necto").path)[.systemFileNumber] as? NSNumber
        #expect(before == after)
    }

    @Test("Replaces existing files and links without modifying their targets", arguments: ["file", "symlink", "dangling"])
    func replaceExistingCLI(kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareDirectory()
        let occupied = fixture.link("necto-cli")
        switch kind {
        case "file": try Data("preserve".utf8).write(to: occupied)
        case "symlink": try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: fixture.root)
        default: try FileManager.default.createSymbolicLink(atPath: occupied.path, withDestinationPath: "/missing/other-cli")
        }
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory, authorize: fixture.execute)
        await installer.install()
        #expect(installer.error == nil)
        #expect(installer.isInstalled)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path) == fixture.tool.path)
        #expect(FileManager.default.fileExists(atPath: fixture.tool.path))
    }

    @Test("Directories are rejected before authorization or any link changes")
    func directoryConflict() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareDirectory()
        let occupied = fixture.link("necto-cli")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let before = try FileManager.default.attributesOfItem(atPath: occupied.path)[.systemFileNumber] as? NSNumber
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { _ in
            Issue.record("Conflicts must not request authorization")
        }
        await installer.install()
        #expect(installer.error?.contains(occupied.path) == true)
        #expect(!installer.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: fixture.link("necto").path))
        let after = try FileManager.default.attributesOfItem(atPath: occupied.path)[.systemFileNumber] as? NSNumber
        #expect(before == after)
    }

    @Test("A missing or non-executable bundled CLI cannot request authorization", arguments: [false, true])
    func unavailable(remove: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if remove {
            try FileManager.default.removeItem(at: fixture.tool)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.tool.path)
        }
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { _ in
            Issue.record("An unavailable CLI must not request authorization")
        }
        #expect(!installer.isAvailable)
        await installer.install()
        #expect(!installer.isInstalled)
        #expect(installer.error != nil)
    }

    @Test("Cancelling authorization makes no changes and permits retry")
    func cancelAndRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var cancelled = true
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { command in
            if cancelled { throw CancellationError() }
            try await fixture.execute(command)
        }
        await installer.install()
        #expect(!installer.isInstalling)
        #expect(!installer.isInstalled)
        #expect(installer.error == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        cancelled = false
        await installer.install()
        #expect(installer.isInstalled)
    }

    @Test("Repeated clicks share one pending authorization")
    func repeatedClicks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var continuation: CheckedContinuation<Void, Never>?
        var approvals = 0
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { command in
            approvals += 1
            await withCheckedContinuation { continuation = $0 }
            try await fixture.execute(command)
        }
        let first = Task { await installer.install() }
        let deadline = ContinuousClock.now + .seconds(3)
        while continuation == nil {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(installer.isInstalling)
        await installer.install()
        installer.refresh()
        #expect(installer.isInstalling)
        continuation?.resume()
        await first.value
        #expect(approvals == 1)
        #expect(installer.isInstalled)
    }

    @Test("The privileged script rechecks conflicts introduced during authorization")
    func conflictAfterAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { command in
            try fixture.prepareDirectory()
            try FileManager.default.createDirectory(at: fixture.link("necto-cli"), withIntermediateDirectories: false)
            try Data("preserve".utf8).write(to: fixture.link("necto-cli").appending(path: "keep"))
            try await fixture.execute(command)
        }
        await installer.install()
        #expect(installer.error != nil)
        #expect(!installer.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: fixture.link("necto").path))
        #expect(try String(contentsOf: fixture.link("necto-cli").appending(path: "keep"), encoding: .utf8) == "preserve")
    }

    @Test("Symlinked destination directories are rejected in preflight and after authorization")
    func symlinkedDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { command in
            try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: fixture.root)
            try await fixture.execute(command)
        }
        await installer.install()
        #expect(installer.error != nil)
        #expect(!installer.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "necto").path))
        let second = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { _ in
            Issue.record("A symlinked bin directory must not request authorization")
        }
        await second.install()
        #expect(second.error?.contains(fixture.directory.path) == true)
    }

    @Test("A successful subprocess alone does not mark the CLI installed")
    func verifyInstallation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = NectoCLIInstaller(tool: fixture.tool, directory: fixture.directory) { _ in }
        await installer.install()
        #expect(installer.error != nil)
        #expect(!installer.isInstalled)
        #expect(!installer.isInstalling)
    }
}
