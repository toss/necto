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
    private func fixture(at root: URL, id: String = "com.example.exporter", exporter: Bool = true) throws -> NectoInstalledPlugin {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = NectoPluginManifest(
            type: exporter ? .eventExporter : nil,
            id: id, name: "Example exporter", description: "Installation fixture", version: "1.0.0",
            author: "Example", icon: .init(systemName: "square"), assets: ["index.html"],
            allowedOrigins: ["self"], operations: []
        )
        try JSONEncoder().encode(manifest).write(to: root.appending(path: "manifest.json"))
        try Data("<!doctype html><title>Example</title>".utf8).write(to: root.appending(path: "index.html"))
        return try NectoPluginLoader.load(from: root)
    }

    private func approved(_ plugin: NectoInstalledPlugin) -> NectoInstalledPlugin {
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
        installed: @escaping @MainActor () -> [NectoInstalledPlugin] = { [] }
    ) -> InstallCoordinator {
        InstallCoordinator(
            shellAccess: NectoShellAccessController(snapshot: .init()) { _ in },
            reload: { [] }, present: {}, delete: { _ in .null }, logFailure: { _, _ in },
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

    @Test("cancelling approval leaves no installed files")
    func cancellationInstallsNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try fixture(at: root.appending(path: "source"), id: "com.example.cancel-\(UUID().uuidString)")
        let directory = root.appending(path: "plugins")
        let coordinator = coordinator(directory: directory)
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        try await waitForApproval(coordinator)
        coordinator.cancelInstall()
        do {
            _ = try await request.value
            Issue.record("Cancelled installation succeeded")
        } catch is CancellationError {} catch { Issue.record(error) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(coordinator.pendingInstall == nil)
    }

    @Test("a commit failure installs nothing and never reloads a runtime")
    func failureInstallsNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try fixture(at: root.appending(path: "source"), id: "com.example.failure-\(UUID().uuidString)")
        let blocked = root.appending(path: "blocked")
        try Data("unchanged".utf8).write(to: blocked)
        var reloads = 0
        let coordinator = InstallCoordinator(
            shellAccess: NectoShellAccessController(snapshot: .init()) { _ in },
            reload: { reloads += 1; return [] }, present: {}, delete: { _ in .null }, logFailure: { _, _ in },
            installedPlugins: { [] }, installationDirectory: blocked
        )
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        try await waitForApproval(coordinator)
        coordinator.confirmInstall()
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }
        #expect(reloads == 0)
        #expect(try Data(contentsOf: blocked) == Data("unchanged".utf8))
        #expect(NectoPluginLibrary.installations[plugin.id] == nil)
    }

    @Test("approval rechecks the installed exporter after staging")
    func rechecksAtApproval() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try fixture(at: root.appending(path: "source"), id: "com.example.pending-\(UUID().uuidString)")
        let first = approved(try fixture(at: root.appending(path: "first")))
        var installed: [NectoInstalledPlugin] = []
        let directory = root.appending(path: "plugins")
        let coordinator = coordinator(directory: directory, installed: { installed })
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        try await waitForApproval(coordinator)
        installed = [first]
        coordinator.confirmInstall()
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(NectoPluginLibrary.installations[plugin.id] == nil)
    }
}
