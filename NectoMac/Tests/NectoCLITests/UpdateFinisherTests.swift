//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Darwin
import Foundation
import Testing

@testable import necto_cli

@Suite("Update finisher")
struct UpdateFinisherTests {
    @Test("parses the hidden update handoff command")
    func parsesCommand() throws {
        let parsed = try NectoCLI.parseAsRoot([
            "_finish-update", "42", "/Applications/Necto.app", "/Applications/.necto-update-test",
        ])
        let command = try #require(parsed as? FinishUpdate)
        #expect(command.oldPID == 42)
        #expect(command.target == "/Applications/Necto.app")
        #expect(command.workspace == "/Applications/.necto-update-test")
    }

    @Test("waits for the old app, preserves its root and opens the new Contents")
    func finishesUpdate() throws {
        try withFixture { fixture in
            let originalInode = try inode(of: fixture.target)
            var running = [true, false]
            var launchedVersions: [String] = []
            var driver = UpdateFinisher.Driver.live
            driver.isProcessRunning = { _ in running.removeFirst() }
            driver.pause = {}
            driver.launch = { launchedVersions.append(try fixture.version(at: $0)) }

            try UpdateFinisher.finish(
                oldPID: 42,
                target: fixture.target,
                workspace: fixture.workspace,
                driver: driver
            )

            let updatedInode = try inode(of: fixture.target)
            let installedVersion = try fixture.version(at: fixture.target)
            #expect(updatedInode == originalInode)
            #expect(installedVersion == "new")
            #expect(launchedVersions == ["new"])
            #expect(!FileManager.default.fileExists(atPath: fixture.workspace.path))
        }
    }

    @Test("restores the old Contents when installation fails")
    func restoresAfterInstallFailure() throws {
        try withFixture { fixture in
            var launchedVersions: [String] = []
            var driver = UpdateFinisher.Driver.live
            driver.isProcessRunning = { _ in false }
            driver.move = { source, destination in
                if source == fixture.stagedContents { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.moveItem(at: source, to: destination)
            }
            driver.launch = { launchedVersions.append(try fixture.version(at: $0)) }

            #expect(throws: UpdateFinisher.Failure.couldNotInstall) {
                try UpdateFinisher.finish(
                    oldPID: 42,
                    target: fixture.target,
                    workspace: fixture.workspace,
                    driver: driver
                )
            }
            let installedVersion = try fixture.version(at: fixture.target)
            #expect(installedVersion == "old")
            #expect(launchedVersions == ["old"])
        }
    }

    @Test("rolls back when opening the new app fails")
    func restoresAfterLaunchFailure() throws {
        try withFixture { fixture in
            var launchedVersions: [String] = []
            var driver = UpdateFinisher.Driver.live
            driver.isProcessRunning = { _ in false }
            driver.launch = { target in
                let version = try fixture.version(at: target)
                launchedVersions.append(version)
                if version == "new" { throw CocoaError(.executableNotLoadable) }
            }

            #expect(throws: UpdateFinisher.Failure.couldNotLaunch) {
                try UpdateFinisher.finish(
                    oldPID: 42,
                    target: fixture.target,
                    workspace: fixture.workspace,
                    driver: driver
                )
            }
            let installedVersion = try fixture.version(at: fixture.target)
            #expect(installedVersion == "old")
            #expect(launchedVersions == ["new", "old"])
        }
    }

    @Test("bounds the wait without touching an app that did not exit")
    func boundsWait() throws {
        try withFixture { fixture in
            var pauses = 0
            var driver = UpdateFinisher.Driver.live
            driver.isProcessRunning = { _ in true }
            driver.pause = { pauses += 1 }
            driver.launch = { _ in Issue.record("must not launch") }

            #expect(throws: UpdateFinisher.Failure.appDidNotExit) {
                try UpdateFinisher.finish(
                    oldPID: 42,
                    target: fixture.target,
                    workspace: fixture.workspace,
                    attempts: 3,
                    driver: driver
                )
            }
            #expect(pauses == 2)
            let installedVersion = try fixture.version(at: fixture.target)
            #expect(installedVersion == "old")
        }
    }
}

private struct Fixture {
    let root: URL
    let target: URL
    let workspace: URL
    var stagedContents: URL { workspace.appending(path: "Contents", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "necto-update-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        target = root.appending(path: "Necto test.app", directoryHint: .isDirectory)
        workspace = root.appending(path: ".necto-update-test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: target.appending(path: "Contents", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: stagedContents, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appending(path: "Contents/version"))
        try Data("new".utf8).write(to: stagedContents.appending(path: "version"))
        try Data("preserve".utf8).write(to: target.appending(path: "dock-identity"))
    }

    func version(at app: URL) throws -> String {
        try String(contentsOf: app.appending(path: "Contents/version"), encoding: .utf8)
    }
}

private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try body(fixture)
}

private func inode(of url: URL) throws -> ino_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
    return info.st_ino
}
