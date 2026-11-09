//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoCLIService
import NectoMacService
import NectoModel
import Testing

@Suite("Exporter installation", .serialized)
@MainActor
struct NectoExporterInstallationTests {
    private func fixture(
        at root: URL,
        id: String = "com.example.exporter",
        exporter: Bool = true,
        version: String = "1.0.0"
    ) throws -> NectoInstalledPackage {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = NectoPluginManifest(
            type: exporter ? .eventExporter : nil,
            id: id, name: "Example exporter", description: "Installation fixture", version: version,
            author: "Example", icon: .init(systemName: "square"), assets: ["index.html"],
            allowedOrigins: ["self"], operations: []
        )
        try JSONEncoder().encode(manifest).write(to: root.appending(path: "manifest.json"))
        try Data("<!doctype html><title>Example</title>".utf8).write(to: root.appending(path: "index.html"))
        return try NectoPackageLoader.load(from: root)
    }

    private func approved(_ plugin: NectoInstalledPackage) -> NectoInstalledPackage {
        var plugin = plugin
        plugin.installation = NectoLocalPluginInstallation(
            pluginID: plugin.id, directoryPath: plugin.rootURL.path,
            approvedContentHash: plugin.contentIdentity
        )
        return plugin
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "necto-exporter-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("approval admits one exporter and same-ID updates, ignoring unapproved folders")
    func oneApprovedExporter() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = approved(try fixture(at: root.appending(path: "first")))
        let second = try fixture(at: root.appending(path: "second"), id: "com.example.other-exporter")

        await #expect(throws: NectoPluginInstaller.Failure.self) {
            _ = try await NectoPluginInstaller.stage(from: second.rootURL, installed: [first])
        }
        let update = try await NectoPluginInstaller.stage(from: first.rootURL, installed: [first])
        #expect(update.previous?.installation == first.installation)

        var unapproved = first
        unapproved.installation = nil
        let staged = try await NectoPluginInstaller.stage(from: second.rootURL, installed: [unapproved])
        #expect(staged.manifest.id == second.id)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "plugins").path))
    }

    private func coordinator(
        directory: URL,
        installed: @escaping @MainActor () -> [NectoInstalledPackage] = { [] },
        reload: @escaping @MainActor () async -> [NectoInstalledPackage] = { [] },
        didInstall: @escaping @MainActor (NectoInstalledPackage) -> Void
    ) -> InstallCoordinator {
        InstallCoordinator(
            shellAccess: NectoShellAccessController(snapshot: .init()) { _ in },
            reload: reload, present: {}, delete: { _ in .null }, logFailure: { _, _ in }, didInstall: didInstall,
            installedPlugins: installed, installationDirectory: directory
        )
    }

    private func waitForApproval(_ coordinator: InstallCoordinator) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while coordinator.pendingInstall == nil && coordinator.installFailure == nil && ContinuousClock.now < deadline {
            await Task.yield()
        }
        _ = try #require(coordinator.pendingInstall)
    }

    @Test("install and update preserve verified bytes and notify only on first approval", arguments: [false, true])
    func installAndUpdate(exporter: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalInstallations = NectoPluginLibrary.installations
        let originalGrants = NectoPluginLibrary.grants
        defer {
            NectoPluginLibrary.installations = originalInstallations
            NectoPluginLibrary.grants = originalGrants
        }
        let source = try fixture(
            at: root.appending(path: "source"),
            id: "com.example.roundtrip-\(UUID().uuidString)", exporter: exporter
        )
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        var installed: [NectoInstalledPackage] = []
        var notifications: [NectoInstalledPackage] = []
        let coordinator = coordinator(
            directory: directory,
            installed: { installed },
            reload: {
                installed = NectoPackageLoader.loadAll(in: directory).packages.map { package in
                    var package = package
                    package.installation = NectoPluginLibrary.installations[package.id]
                    return package
                }
                return installed
            },
            didInstall: { notifications.append($0) }
        )

        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(source.rootURL.path)) }
        try await waitForApproval(coordinator)
        #expect(notifications.isEmpty)
        coordinator.confirmInstall()
        _ = try await request.value
        let first = try #require(installed.first)
        #expect(first.manifest == source.manifest)
        #expect(first.archive == source.archive)
        #expect(first.contentIdentity == source.contentIdentity)
        #expect(first.source == .installed)
        let approval = try #require(first.installation)
        #expect(first.principal == approval.principal)
        #expect(approval.approvedContentHash == first.contentIdentity)
        #expect(notifications.map(\.id) == [first.id])
        #expect(notifications.map(\.contentIdentity) == [first.contentIdentity])
        #expect(notifications.first?.installation == approval)

        await coordinator.reloadPlugins()
        #expect(notifications.count == 1)

        try Data("<!doctype html><title>Updated</title>".utf8).write(to: source.rootURL.appending(path: "index.html"))
        let updatedSource = try NectoPackageLoader.load(from: source.rootURL)
        let update = Task { try await coordinator.installPluginFromCLI(source: .localPath(source.rootURL.path)) }
        try await waitForApproval(coordinator)
        coordinator.confirmInstall()
        _ = try await update.value
        let updated = try #require(installed.first)
        #expect(updated.rootURL == first.rootURL)
        #expect(updated.manifest == updatedSource.manifest)
        #expect(updated.archive == updatedSource.archive)
        #expect(updated.contentIdentity == updatedSource.contentIdentity)
        #expect(updated.contentIdentity != first.contentIdentity)
        #expect(updated.installation?.id == approval.id)
        #expect(updated.installation?.approvedContentHash == updated.contentIdentity)
        #expect(updated.principal == first.principal)
        #expect(notifications.count == 1)
    }

    @Test("reviewing a package already on disk notifies on its first approval")
    func firstApprovalNotifies() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalInstallations = NectoPluginLibrary.installations
        let originalGrants = NectoPluginLibrary.grants
        defer {
            NectoPluginLibrary.installations = originalInstallations
            NectoPluginLibrary.grants = originalGrants
        }
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        let id = "com.example.review-\(UUID().uuidString)"
        let plugin = try fixture(at: directory.appending(path: id, directoryHint: .isDirectory), id: id)
        var notifications: [NectoInstalledPackage] = []
        let coordinator = coordinator(
            directory: directory,
            installed: { [plugin] },
            reload: {
                var loaded = plugin
                loaded.installation = NectoPluginLibrary.installations[id]
                return [loaded]
            },
            didInstall: { notifications.append($0) }
        )

        coordinator.review(plugin)
        try await waitForApproval(coordinator)
        coordinator.confirmInstall()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while coordinator.isCommitting && ContinuousClock.now < deadline {
            await Task.yield()
        }
        let approval = try #require(NectoPluginLibrary.installations[id])
        #expect(notifications.map(\.id) == [id])
        #expect(notifications.first?.installation == approval)
    }

    @Test("cancelling approval leaves no installed files")
    func cancellationInstallsNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try fixture(at: root.appending(path: "source"), id: "com.example.cancel-\(UUID().uuidString)")
        let directory = root.appending(path: "plugins")
        var notifications = 0
        let coordinator = coordinator(directory: directory, didInstall: { _ in notifications += 1 })
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        try await waitForApproval(coordinator)
        coordinator.cancelInstall()
        do {
            _ = try await request.value
            Issue.record("Cancelled installation succeeded")
        } catch is CancellationError {} catch { Issue.record(error) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(coordinator.pendingInstall == nil)
        #expect(notifications == 0)
    }

    @Test("a commit failure installs nothing and never reloads a runtime")
    func failureInstallsNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try fixture(at: root.appending(path: "source"), id: "com.example.failure-\(UUID().uuidString)")
        let blocked = root.appending(path: "blocked")
        try Data("unchanged".utf8).write(to: blocked)
        var reloads = 0
        var notifications = 0
        let coordinator = coordinator(
            directory: blocked,
            reload: { reloads += 1; return [] },
            didInstall: { _ in notifications += 1 }
        )
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        try await waitForApproval(coordinator)
        coordinator.confirmInstall()
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }
        #expect(reloads == 0)
        #expect(notifications == 0)
        #expect(try Data(contentsOf: blocked) == Data("unchanged".utf8))
        #expect(NectoPluginLibrary.installations[plugin.id] == nil)
    }

    @Test("a reload returning different content for the approved ID sends no installation notification")
    func reloadMismatchDoesNotNotify() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalInstallations = NectoPluginLibrary.installations
        let originalGrants = NectoPluginLibrary.grants
        defer {
            NectoPluginLibrary.installations = originalInstallations
            NectoPluginLibrary.grants = originalGrants
        }
        let plugin = try fixture(at: root.appending(path: "source"), id: "com.example.mismatch-\(UUID().uuidString)")
        let mismatch = try fixture(at: root.appending(path: "mismatch"), id: plugin.id, version: "2.0.0")
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        var notifications = 0
        let coordinator = coordinator(
            directory: directory,
            reload: { [mismatch] },
            didInstall: { _ in notifications += 1 }
        )
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        try await waitForApproval(coordinator)
        coordinator.confirmInstall()
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }
        #expect(NectoPluginLibrary.installations[plugin.id]?.approvedContentHash == plugin.contentIdentity)
        #expect(notifications == 0)
    }

    @Test("approval rechecks the installed exporter after staging")
    func rechecksAtApproval() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try fixture(at: root.appending(path: "source"), id: "com.example.pending-\(UUID().uuidString)")
        let first = approved(try fixture(at: root.appending(path: "first")))
        var installed: [NectoInstalledPackage] = []
        let directory = root.appending(path: "plugins")
        let coordinator = coordinator(directory: directory, installed: { installed }) { _ in
            Issue.record("Rejected installation sent a notification")
        }
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        try await waitForApproval(coordinator)
        installed = [first]
        coordinator.confirmInstall()
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(NectoPluginLibrary.installations[plugin.id] == nil)
    }
}
