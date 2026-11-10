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
        version: String = "1.0.0",
        operations: [NectoOperation] = []
    ) throws -> NectoInstalledPackage {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = NectoPluginManifest(
            type: exporter ? .eventExporter : nil,
            id: id, name: "Example exporter", description: "Installation fixture", version: version,
            author: "Example", icon: .init(systemName: "square"), assets: ["index.html"],
            allowedOrigins: ["self"], operations: operations
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

    private func shellOperation(commands: [String]? = ["pwd", "uname -s"]) -> NectoOperation {
        var command: [String: NectoJSONValue] = ["type": "string"]
        if let commands { command["enum"] = .array(commands.map(NectoJSONValue.string)) }
        return NectoOperation(
            id: "environment.read", title: "Read environment", description: "Read local diagnostics",
            kind: .once, binding: .init(name: "necto.desktop.shell.execute", version: 1),
            inputSchema: ["type": "object", "properties": ["command": .object(command)], "required": ["command"]],
            outputSchema: ["type": "object"], timeoutMs: 5_000
        )
    }

    private func loadInstallations(in directory: URL) -> [NectoInstalledPackage] {
        NectoPackageLoader.loadAll(in: directory).packages.map { package in
            var package = package
            package.installation = NectoPluginLibrary.installations[package.id]
            return package
        }
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
        shellAccess: NectoShellAccessController? = nil,
        installed: @escaping @MainActor () -> [NectoInstalledPackage] = { [] },
        reload: @escaping @MainActor () async -> [NectoInstalledPackage] = { [] },
        present: @escaping @MainActor () throws -> Void = {},
        didInstall: @escaping @MainActor (NectoInstalledPackage) -> Void
    ) -> InstallCoordinator {
        InstallCoordinator(
            shellAccess: shellAccess ?? NectoShellAccessController(snapshot: .init()) { _ in },
            reload: reload, present: present, delete: { _ in .null }, logFailure: { _, _ in }, didInstall: didInstall,
            installedPlugins: installed, installationDirectory: directory
        )
    }

    @discardableResult
    private func waitForApproval(_ coordinator: InstallCoordinator) async throws -> InstallCoordinator.PendingInstall {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while coordinator.pendingInstall == nil && coordinator.installFailure == nil && ContinuousClock.now < deadline {
            await Task.yield()
        }
        return try #require(coordinator.pendingInstall)
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
            id: "com.example.roundtrip-\(UUID().uuidString)", exporter: exporter,
            operations: exporter ? [] : [shellOperation()]
        )
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        var installed: [NectoInstalledPackage] = []
        var notifications: [NectoInstalledPackage] = []
        let coordinator = coordinator(
            directory: directory,
            installed: { installed },
            reload: {
                installed = loadInstallations(in: directory)
                return installed
            },
            didInstall: { notifications.append($0) }
        )

        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(source.rootURL.path)) }
        let pending = try await waitForApproval(coordinator)
        if exporter {
            #expect(pending.shellReview?.requiresAccessChoice == false)
        } else {
            #expect(pending.shellReview == nil)
        }
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

    @Test("the selected shell access replaces the prior grant before reload", arguments: NectoShellAccessLevel.allCases)
    func selectedShellAccess(level: NectoShellAccessLevel) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalInstallations = NectoPluginLibrary.installations
        let originalGrants = NectoPluginLibrary.grants
        defer {
            NectoPluginLibrary.installations = originalInstallations
            NectoPluginLibrary.grants = originalGrants
        }
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        let id = "com.example.shell-update-\(UUID().uuidString)"
        let old = approved(try fixture(at: directory.appending(path: id, directoryHint: .isDirectory), id: id))
        let installation = try #require(old.installation)
        NectoPluginLibrary.installations[id] = installation
        let priorGrant = NectoShellGrant(principal: installation.principal, level: .commandApproval, approvedCommands: ["whoami"])
        let initial = NectoShellPolicySnapshot(grants: [priorGrant])
        var persisted = initial
        let access = NectoShellAccessController(snapshot: initial) { persisted = $0 }
        let source = try fixture(at: root.appending(path: "source"), id: id, version: "2.0.0", operations: [shellOperation()])
        let expected = NectoShellGrant(
            principal: installation.principal, level: level,
            approvedCommands: level == .commandApproval ? ["pwd", "uname -s"] : []
        )
        var grantAtReload: NectoShellGrant?
        var persistedAtReload: NectoShellPolicySnapshot?
        let coordinator = coordinator(
            directory: directory,
            shellAccess: access,
            installed: { [old] },
            reload: {
                grantAtReload = await access.policy.access(for: installation.principal)
                persistedAtReload = persisted
                return loadInstallations(in: directory)
            },
            didInstall: { _ in Issue.record("An update sent a first-install notification") }
        )

        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(source.rootURL.path)) }
        defer { request.cancel() }
        let review = try #require(try await waitForApproval(coordinator).shellReview)
        #expect(review.requiresAccessChoice)
        #expect(Set(review.availableAccessLevels) == Set(NectoShellAccessLevel.allCases))
        #expect(review.currentGrant == priorGrant)
        #expect(persisted == initial)
        coordinator.confirmInstall(shellAccess: level)
        _ = try await request.value

        #expect(grantAtReload == expected)
        #expect(persistedAtReload?.grants == [expected])
        #expect(access.snapshot.grants == [expected])
        #expect(NectoPluginLibrary.installations[id]?.principal == installation.principal)
        #expect(NectoPluginLibrary.installations[id]?.approvedContentHash == source.contentIdentity)
    }

    @Test("global Full Access or no shell request leaves individual shell grants unchanged", arguments: [false, true], [false, true])
    func noIndividualShellChoice(globalFullAccess: Bool, updating: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalInstallations = NectoPluginLibrary.installations
        let originalGrants = NectoPluginLibrary.grants
        defer {
            NectoPluginLibrary.installations = originalInstallations
            NectoPluginLibrary.grants = originalGrants
        }
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        let id = "com.example.shell-unchanged-\(UUID().uuidString)"
        let source = try fixture(
            at: root.appending(path: "source"), id: id, version: "2.0.0",
            operations: globalFullAccess ? [shellOperation()] : []
        )
        var initial = NectoShellPolicySnapshot(isFullAccessEnabled: globalFullAccess)
        var installed: [NectoInstalledPackage] = []
        if updating {
            let old = approved(try fixture(at: directory.appending(path: id, directoryHint: .isDirectory), id: id))
            let installation = try #require(old.installation)
            NectoPluginLibrary.installations[id] = installation
            initial.grants = [.init(principal: installation.principal, level: .commandApproval, approvedCommands: ["whoami"])]
            installed = [old]
        }
        var savedSnapshots: [NectoShellPolicySnapshot] = []
        let access = NectoShellAccessController(snapshot: initial) { savedSnapshots.append($0) }
        let coordinator = coordinator(
            directory: directory,
            shellAccess: access,
            installed: { installed },
            reload: { loadInstallations(in: directory) },
            didInstall: { _ in }
        )
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(source.rootURL.path)) }
        defer { request.cancel() }
        let review = try #require(try await waitForApproval(coordinator).shellReview)
        #expect(review.requestsShellAccess == globalFullAccess)
        #expect(!review.requiresAccessChoice)
        #expect(review.availableAccessLevels.isEmpty)
        coordinator.confirmInstall()
        _ = try await request.value

        #expect(access.snapshot == initial)
        #expect(await access.policy.snapshot() == initial)
        #expect(savedSnapshots.isEmpty)
        #expect(NectoPluginLibrary.installations[id]?.approvedContentHash == source.contentIdentity)
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

    @Test("cancelling shell review leaves no installed files or grant")
    func cancellationInstallsNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalRejections = NectoPluginLibrary.rejectedExporterContentHashes
        defer { NectoPluginLibrary.rejectedExporterContentHashes = originalRejections }
        let plugin = try fixture(
            at: root.appending(path: "source"), id: "com.example.cancel-\(UUID().uuidString)", operations: [shellOperation()]
        )
        let directory = root.appending(path: "plugins")
        let access = NectoShellAccessController(snapshot: .init()) { _ in Issue.record("Cancellation saved shell access") }
        var notifications = 0
        let coordinator = coordinator(directory: directory, shellAccess: access, didInstall: { _ in notifications += 1 })
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        defer { request.cancel() }
        let pending = try await waitForApproval(coordinator)
        #expect(pending.shellReview?.requiresAccessChoice == true)
        coordinator.cancelInstall()
        do {
            _ = try await request.value
            Issue.record("Cancelled installation succeeded")
        } catch is CancellationError {} catch { Issue.record(error) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(NectoPluginLibrary.installations[plugin.id] == nil)
        #expect(NectoPluginLibrary.rejectedExporterContentHashes == originalRejections)
        #expect(await access.policy.snapshot().grants.isEmpty)
        #expect(coordinator.pendingInstall == nil)
        #expect(notifications == 0)
    }

    @Test("invalid shell choices fail before installing", arguments: [false, true])
    func rejectsInvalidShellChoice(hasCommandEnum: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try fixture(
            at: root.appending(path: "source"), id: "com.example.invalid-shell-\(UUID().uuidString)",
            operations: [shellOperation(commands: hasCommandEnum ? ["pwd"] : nil)]
        )
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        let access = NectoShellAccessController(snapshot: .init()) { _ in Issue.record("An invalid choice saved shell access") }
        let coordinator = coordinator(
            directory: directory,
            shellAccess: access,
            reload: { Issue.record("An invalid choice reloaded plugins"); return [] },
            didInstall: { _ in Issue.record("An invalid choice sent an installation notification") }
        )
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        defer { request.cancel() }
        let pending = try await waitForApproval(coordinator)
        let review = try #require(pending.shellReview)
        #expect(review.requiresAccessChoice)
        #expect(review.availableAccessLevels.contains(.commandApproval) == hasCommandEnum)
        coordinator.confirmInstall(shellAccess: hasCommandEnum ? nil : .commandApproval)
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }
        #expect(coordinator.installFailure == NectoShellPolicy.InstallationError.unavailableAccessLevel.localizedDescription)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(NectoPluginLibrary.installations[plugin.id] == nil)
        #expect(await access.policy.snapshot().grants.isEmpty)
    }

    @Test("changing global Full Access after review requires a fresh review before installing")
    func rejectsStaleShellReview() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try fixture(
            at: root.appending(path: "source"), id: "com.example.stale-shell-\(UUID().uuidString)", operations: [shellOperation()]
        )
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        var savedSnapshots: [NectoShellPolicySnapshot] = []
        let access = NectoShellAccessController(snapshot: .init()) { savedSnapshots.append($0) }
        let coordinator = coordinator(
            directory: directory,
            shellAccess: access,
            reload: { Issue.record("A stale review reloaded plugins"); return [] },
            didInstall: { _ in Issue.record("A stale review sent an installation notification") }
        )
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        defer { request.cancel() }
        let pending = try await waitForApproval(coordinator)
        #expect(pending.shellReview?.requiresAccessChoice == true)
        await access.setFullAccessEnabled(true)
        coordinator.confirmInstall(shellAccess: .protected)
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }
        #expect(coordinator.installFailure == NectoShellPolicy.InstallationError.staleReview.localizedDescription)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(NectoPluginLibrary.installations[plugin.id] == nil)
        #expect(savedSnapshots == [.init(isFullAccessEnabled: true)])
        #expect(await access.policy.snapshot() == .init(isFullAccessEnabled: true))
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

    @Test("a reload returning different content rolls back shell access without notifying", arguments: [false, true])
    func reloadMismatchRestoresShellAccess(updating: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalInstallations = NectoPluginLibrary.installations
        let originalGrants = NectoPluginLibrary.grants
        defer {
            NectoPluginLibrary.installations = originalInstallations
            NectoPluginLibrary.grants = originalGrants
        }
        let plugin = try fixture(
            at: root.appending(path: "source"), id: "com.example.mismatch-\(UUID().uuidString)", operations: [shellOperation()]
        )
        let mismatch = try fixture(at: root.appending(path: "mismatch"), id: plugin.id, version: "2.0.0")
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        var initial = NectoShellPolicySnapshot()
        var installed: [NectoInstalledPackage] = []
        if updating {
            let old = approved(try fixture(
                at: directory.appending(path: plugin.id, directoryHint: .isDirectory), id: plugin.id, version: "0.9.0"
            ))
            let installation = try #require(old.installation)
            NectoPluginLibrary.installations[plugin.id] = installation
            initial.grants = [.init(principal: installation.principal, level: .commandApproval, approvedCommands: ["whoami"])]
            installed = [old]
        }
        var savedSnapshots: [NectoShellPolicySnapshot] = []
        let access = NectoShellAccessController(snapshot: initial) { savedSnapshots.append($0) }
        var grantAtReload: NectoShellGrant?
        var notifications = 0
        let coordinator = coordinator(
            directory: directory,
            shellAccess: access,
            installed: { installed },
            reload: {
                if let principal = NectoPluginLibrary.installations[plugin.id]?.principal {
                    grantAtReload = await access.policy.access(for: principal)
                }
                return [mismatch]
            },
            didInstall: { _ in notifications += 1 }
        )
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(plugin.rootURL.path)) }
        defer { request.cancel() }
        try await waitForApproval(coordinator)
        coordinator.confirmInstall(shellAccess: .fullAccess)
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }
        let grant = try #require(grantAtReload)
        #expect(grant.level == .fullAccess)
        #expect(savedSnapshots == [.init(grants: [grant]), initial])
        #expect(access.snapshot == initial)
        #expect(await access.policy.snapshot() == initial)
        #expect(NectoPluginLibrary.installations[plugin.id]?.approvedContentHash == plugin.contentIdentity)
        #expect(notifications == 0)
    }

    @Test("a changed installation record or changed files invalidate the review", arguments: [false, true])
    func rejectsChangedInstallation(changeRecord: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalInstallations = NectoPluginLibrary.installations
        let originalGrants = NectoPluginLibrary.grants
        defer {
            NectoPluginLibrary.installations = originalInstallations
            NectoPluginLibrary.grants = originalGrants
        }
        let directory = root.appending(path: "plugins", directoryHint: .isDirectory)
        let id = "com.example.changed-installation-\(UUID().uuidString)"
        let old = approved(try fixture(at: directory.appending(path: id, directoryHint: .isDirectory), id: id))
        let installation = try #require(old.installation)
        NectoPluginLibrary.installations[id] = installation
        let source = try fixture(at: root.appending(path: "source"), id: id, version: "2.0.0", operations: [shellOperation()])
        let initial = NectoShellPolicySnapshot(grants: [
            .init(principal: installation.principal, level: .commandApproval, approvedCommands: ["whoami"]),
        ])
        let access = NectoShellAccessController(snapshot: initial) { _ in Issue.record("A stale installation saved shell access") }
        let coordinator = coordinator(
            directory: directory,
            shellAccess: access,
            installed: { [old] },
            reload: { Issue.record("A stale installation reloaded plugins"); return [] },
            didInstall: { _ in Issue.record("A stale installation sent an installation notification") }
        )
        let request = Task { try await coordinator.installPluginFromCLI(source: .localPath(source.rootURL.path)) }
        defer { request.cancel() }
        try await waitForApproval(coordinator)
        if changeRecord {
            NectoPluginLibrary.installations[id] = approved(old).installation
        } else {
            try Data("<!doctype html><title>Externally changed</title>".utf8).write(to: old.rootURL.appending(path: "index.html"))
        }
        let current = try NectoPackageLoader.load(from: old.rootURL)
        let record = NectoPluginLibrary.installations[id]
        coordinator.confirmInstall(shellAccess: .fullAccess)
        await #expect(throws: NectoBridgeError.self) { _ = try await request.value }

        #expect(coordinator.installFailure == NectoLocalPluginFiles.Failure.changedSinceReview.localizedDescription)
        #expect(try NectoPackageLoader.load(from: old.rootURL).archive == current.archive)
        #expect(NectoPluginLibrary.installations[id] == record)
        #expect(await access.policy.snapshot() == initial)
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

    private func withInstallationDirectory(_ run: @MainActor (URL) async throws -> Void) async throws {
        let root = try temporaryDirectory()
        let originalInstallations = NectoPluginLibrary.installations
        let originalGrants = NectoPluginLibrary.grants
        let originalRejections = NectoPluginLibrary.rejectedExporterContentHashes
        defer {
            try? FileManager.default.removeItem(at: root)
            NectoPluginLibrary.installations = originalInstallations
            NectoPluginLibrary.grants = originalGrants
            NectoPluginLibrary.rejectedExporterContentHashes = originalRejections
        }
        try await run(root.appending(path: "plugins", directoryHint: .isDirectory))
    }

    enum UIReviewExit: CaseIterable {
        case cancel, dismiss, reject
    }

    @Test("only explicitly rejecting a UI review suppresses the warning", arguments: UIReviewExit.allCases)
    func uiExporterReviewExit(exit: UIReviewExit) async throws {
        try await withInstallationDirectory { directory in
            let id = "com.example.ui-reject-\(UUID().uuidString)"
            let plugin = try fixture(at: directory.appending(path: id), id: id, operations: [shellOperation()])
            let access = NectoShellAccessController(snapshot: .init()) { _ in
                Issue.record("Ending a review saved shell access")
            }
            let originalGrants = NectoPluginLibrary.grants
            let coordinator = coordinator(directory: directory, shellAccess: access, installed: {
                loadInstallations(in: directory)
            }, reload: {
                Issue.record("Ending a review reloaded plugins")
                return []
            }, didInstall: { _ in Issue.record("Ending a review sent an installation notification") })

            coordinator.review(plugin)
            try await waitForApproval(coordinator)
            switch exit {
            case .cancel: coordinator.cancelInstall()
            case .dismiss: coordinator.dismissPrompt()
            case .reject: coordinator.rejectInstall()
            }

            #expect(coordinator.pendingInstall == nil)
            #expect(NectoPluginLibrary.rejectedExporterContentHashes[id] == (exit == .reject ? plugin.contentIdentity : nil))
            #expect((cliCoordinator(directory: directory).exporterWarning() == nil) == (exit == .reject))
            #expect(NectoPluginLibrary.installations[id] == nil)
            #expect(NectoPluginLibrary.grants == originalGrants)
            #expect(await access.policy.snapshot().grants.isEmpty)
            #expect(try NectoPackageLoader.load(from: plugin.rootURL).archive == plugin.archive)
        }
    }

    private func cliCoordinator(
        directory: URL,
        shellAccess: NectoShellAccessController? = nil,
        reload: @escaping @MainActor () async -> [NectoInstalledPackage] = {
            Issue.record("Unexpected reload during exporter approval")
            return []
        },
        didInstall: @escaping @MainActor (NectoInstalledPackage) -> Void = { _ in
            Issue.record("Unexpected exporter installation notification")
        }
    ) -> InstallCoordinator {
        coordinator(
            directory: directory, shellAccess: shellAccess,
            installed: { loadInstallations(in: directory) }, reload: reload,
            present: { Issue.record("CLI exporter approval presented UI") }, didInstall: didInstall
        )
    }

    @Test("CLI review is read-only and approval applies the selected shell access before reloading",
          arguments: NectoShellAccessLevel.allCases)
    func cliExporterShellAccess(level: NectoShellAccessLevel) async throws {
        try await withInstallationDirectory { directory in
            let id = "com.example.cli-shell-update-\(UUID().uuidString)"
            let path = directory.appending(path: id, directoryHint: .isDirectory)
            let old = approved(try fixture(at: path, id: id))
            let installation = try #require(old.installation)
            NectoPluginLibrary.installations[id] = installation
            let operation = shellOperation()
            let plugin = try fixture(at: path, id: id, version: "2.0.0", operations: [operation])
            let initial = NectoShellPolicySnapshot(grants: [
                .init(principal: installation.principal, level: .commandApproval, approvedCommands: ["whoami"]),
            ])
            var persisted = initial
            let access = NectoShellAccessController(snapshot: initial) { persisted = $0 }
            let originalGrants = NectoPluginLibrary.grants
            var grantsAtReload: NectoPluginGrants?
            var shellAtReload: NectoShellGrant?
            var persistedAtReload: NectoShellPolicySnapshot?
            let coordinator = cliCoordinator(directory: directory, shellAccess: access, reload: {
                grantsAtReload = NectoPluginLibrary.grants
                shellAtReload = await access.policy.access(for: installation.principal)
                persistedAtReload = persisted
                return loadInstallations(in: directory)
            })

            let review = try await coordinator.reviewExporterFromCLI()
            #expect(review["pending"] == true)
            #expect(review["exporter"]?["id"] == .string(id))
            #expect(review["exporter"]?["version"] == "2.0.0")
            #expect(review["exporter"]?["contentHash"] == .string(plugin.contentIdentity))
            #expect(review["collection"]?["includesCurrentAndFuturePlugins"] == true)
            #expect(review["collection"]?["preservesExclusions"] == true)
            #expect(review["shellAccess"]?["availableChoices"] == ["full", "commands", "none"])
            #expect(coordinator.pendingInstall == nil)
            #expect(NectoPluginLibrary.installations[id] == installation)
            #expect(NectoPluginLibrary.grants == originalGrants)
            #expect(persisted == initial)
            #expect(try NectoPackageLoader.load(from: path).archive == plugin.archive)
            #expect(grantsAtReload == nil)

            let choice: NectoExporterApproval.ShellAccess = switch level {
            case .protected: .none
            case .commandApproval: .commands
            case .fullAccess: .full
            }
            _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: choice))

            let expected = NectoShellGrant(
                principal: installation.principal, level: level,
                approvedCommands: level == .commandApproval ? ["pwd", "uname -s"] : []
            )
            #expect(shellAtReload == expected)
            #expect(persistedAtReload?.grants == [expected])
            #expect(grantsAtReload?.bridges(for: installation.principal) == [operation.binding.identity])
            #expect(NectoPluginLibrary.installations[id]?.principal == installation.principal)
            #expect(NectoPluginLibrary.installations[id]?.approvedContentHash == plugin.contentIdentity)
        }
    }

    @Test("CLI approval without a required shell choice preserves prior grants", arguments: [false, true])
    func cliExporterPreservesShellAccess(globalFullAccess: Bool) async throws {
        try await withInstallationDirectory { directory in
            let id = "com.example.cli-unchanged-\(UUID().uuidString)"
            let path = directory.appending(path: id, directoryHint: .isDirectory)
            let old = approved(try fixture(at: path, id: id))
            let installation = try #require(old.installation)
            NectoPluginLibrary.installations[id] = installation
            let plugin = try fixture(
                at: path, id: id, version: "2.0.0", operations: globalFullAccess ? [shellOperation()] : []
            )
            let initial = NectoShellPolicySnapshot(isFullAccessEnabled: globalFullAccess, grants: [
                .init(principal: installation.principal, level: .commandApproval, approvedCommands: ["whoami"]),
            ])
            let access = NectoShellAccessController(snapshot: initial) { _ in
                Issue.record("Preserving shell access saved a new snapshot")
            }
            let coordinator = cliCoordinator(directory: directory, shellAccess: access, reload: {
                loadInstallations(in: directory)
            })

            #expect(try await coordinator.reviewExporterFromCLI()["pending"] == true)
            _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: nil))

            #expect(await access.policy.snapshot() == initial)
            #expect(NectoPluginLibrary.installations[id]?.approvedContentHash == plugin.contentIdentity)
        }
    }

    @Test("CLI rejection silences the warning across coordinators and still allows explicit review and approval")
    func cliExporterRejectsAndReviewsAgain() async throws {
        try await withInstallationDirectory { directory in
            let id = "com.example.cli-reject-\(UUID().uuidString)"
            let plugin = try fixture(at: directory.appending(path: id), id: id, operations: [shellOperation()])
            let access = NectoShellAccessController(snapshot: .init()) { _ in }
            let originalGrants = NectoPluginLibrary.grants
            var reloads = 0
            var notifications: [String] = []
            let coordinator = cliCoordinator(directory: directory, shellAccess: access, reload: {
                reloads += 1
                return loadInstallations(in: directory)
            }, didInstall: { notifications.append($0.id) })

            #expect(coordinator.exporterWarning() == ["exporters": [[
                "id": .string(id), "name": .string(plugin.manifest.name), "requestsShellAccess": true,
            ]]])
            #expect(coordinator.pendingInstall == nil)
            await #expect(throws: (any Error).self) {
                _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: .full))
            }
            await #expect(throws: (any Error).self) { _ = try await coordinator.rejectExporterFromCLI() }
            #expect(try await coordinator.reviewExporterFromCLI()["pending"] == true)
            let rejection = try await coordinator.rejectExporterFromCLI()
            #expect(rejection["rejected"] == true)
            #expect(rejection["pluginID"] == .string(id))
            #expect(NectoPluginLibrary.rejectedExporterContentHashes[id] == plugin.contentIdentity)
            #expect(cliCoordinator(directory: directory).exporterWarning() == nil)
            await #expect(throws: (any Error).self) {
                _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: .full))
            }
            #expect(try NectoPackageLoader.load(from: plugin.rootURL).archive == plugin.archive)
            #expect(NectoPluginLibrary.installations[id] == nil)
            #expect(NectoPluginLibrary.grants == originalGrants)
            #expect(await access.policy.snapshot() == .init())
            #expect(reloads == 0)
            #expect(notifications.isEmpty)

            #expect(try await coordinator.reviewExporterFromCLI()["exporter"]?["id"] == .string(id))
            _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: .full))
            #expect(reloads == 1)
            #expect(notifications == [id])
            #expect(try await coordinator.reviewExporterFromCLI()["pending"] == false)
        }
    }

    @Test("rejecting a stale review silences only the bytes the CLI reviewed")
    func cliExporterRejectsReviewedBytes() async throws {
        try await withInstallationDirectory { directory in
            let id = "com.example.cli-reject-stale-\(UUID().uuidString)"
            let path = directory.appending(path: id, directoryHint: .isDirectory)
            let original = try fixture(at: path, id: id)
            let coordinator = cliCoordinator(directory: directory)
            let review = try await coordinator.reviewExporterFromCLI()
            #expect(review["exporter"]?["contentHash"] == .string(original.contentIdentity))
            #expect(coordinator.exporterWarning()?["exporters"]?.arrayValue?.first?["requestsShellAccess"] == false)

            let updated = try fixture(at: path, id: id, operations: [shellOperation()])
            #expect(updated.contentIdentity != original.contentIdentity)
            let expectedWarning: NectoJSONValue = ["exporters": [[
                "id": .string(id), "name": .string(updated.manifest.name), "requestsShellAccess": true,
            ]]]
            #expect(coordinator.exporterWarning() == expectedWarning)
            #expect(try await coordinator.rejectExporterFromCLI()["rejected"] == true)
            #expect(NectoPluginLibrary.rejectedExporterContentHashes[id] == original.contentIdentity)
            #expect(cliCoordinator(directory: directory).exporterWarning() == expectedWarning)
            #expect(NectoPluginLibrary.installations[id] == nil)
        }
    }

    @Test("CLI review and warnings exclude ordinary plugins and approved exporters")
    func cliExporterHasNoCandidate() async throws {
        try await withInstallationDirectory { directory in
            let coordinator = cliCoordinator(directory: directory)
            #expect(try await coordinator.reviewExporterFromCLI()["pending"] == false)
            #expect(coordinator.exporterWarning() == nil)
            let id = "com.example.cli-approved-\(UUID().uuidString)"
            let exporter = try approved(fixture(at: directory.appending(path: id), id: id))
            NectoPluginLibrary.installations[id] = exporter.installation
            _ = try fixture(at: directory.appending(path: "ordinary"), id: "com.example.ordinary", exporter: false)

            #expect(try await coordinator.reviewExporterFromCLI()["pending"] == false)
            #expect(coordinator.exporterWarning() == nil)
        }
    }

    @Test("CLI does not select or approve an exporter when several candidates are pending", arguments: [false, true])
    func cliExporterRefusesMultipleCandidates(changedAfterReview: Bool) async throws {
        try await withInstallationDirectory { directory in
            let first = try fixture(at: directory.appending(path: "first"), id: "com.example.cli-first-\(UUID().uuidString)")
            let coordinator = cliCoordinator(directory: directory)
            if changedAfterReview {
                #expect(try await coordinator.reviewExporterFromCLI()["exporter"]?["id"] == .string(first.id))
            }
            let second = try fixture(at: directory.appending(path: "second"), id: "com.example.cli-second-\(UUID().uuidString)")

            let warnings = try #require(coordinator.exporterWarning()?["exporters"]?.arrayValue)
            #expect(warnings.count == 2)
            #expect(Set(warnings.compactMap { $0["id"]?.stringValue }) == Set([first.id, second.id]))
            NectoPluginLibrary.rejectedExporterContentHashes[first.id] = first.contentIdentity
            let remainingWarning = try #require(coordinator.exporterWarning())
            #expect(remainingWarning["multipleCandidates"] == true)
            #expect(remainingWarning["exporters"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == [second.id])
            if !changedAfterReview {
                await #expect(throws: (any Error).self) { _ = try await coordinator.reviewExporterFromCLI() }
            }
            await #expect(throws: (any Error).self) {
                _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: nil))
            }
            #expect(NectoPluginLibrary.installations[first.id] == nil)
            #expect(NectoPluginLibrary.installations[second.id] == nil)
        }
    }

    enum CLIReviewChange: CaseIterable {
        case files, policy, replacementRecord, alreadyApproved
    }

    @Test("CLI approval requires a fresh review after files, policy or installation records change",
          arguments: CLIReviewChange.allCases)
    func cliExporterRejectsStaleReview(change: CLIReviewChange) async throws {
        try await withInstallationDirectory { directory in
            let id = "com.example.cli-stale-\(UUID().uuidString)"
            let path = directory.appending(path: id, directoryHint: .isDirectory)
            let old = approved(try fixture(at: path, id: id))
            let originalInstallation = try #require(old.installation)
            NectoPluginLibrary.installations[id] = originalInstallation
            let operation = shellOperation()
            let plugin = try fixture(at: path, id: id, version: "2.0.0", operations: [operation])
            var savedSnapshots: [NectoShellPolicySnapshot] = []
            let access = NectoShellAccessController(snapshot: .init()) { savedSnapshots.append($0) }
            let coordinator = cliCoordinator(directory: directory, shellAccess: access)
            #expect(try await coordinator.reviewExporterFromCLI()["pending"] == true)

            switch change {
            case .files:
                try Data("<!doctype html><title>Changed</title>".utf8).write(to: path.appending(path: "index.html"))
                #expect(coordinator.exporterWarning()?["exporters"]?.arrayValue?.first?["id"] == .string(id))
            case .policy:
                await access.setFullAccessEnabled(true)
            case .replacementRecord:
                NectoPluginLibrary.installations[id] = approved(old).installation
            case .alreadyApproved:
                var installation = originalInstallation
                installation.approveUpdate(contentHash: plugin.contentIdentity, origin: nil)
                NectoPluginLibrary.installations[id] = installation
                NectoPluginLibrary.grants.grant([operation.binding.identity], to: installation.principal)
            }
            let current = try NectoPackageLoader.load(from: path)
            let currentInstallation = NectoPluginLibrary.installations[id]
            let currentGrants = NectoPluginLibrary.grants
            let currentPolicy = await access.policy.snapshot()
            let currentSnapshots = savedSnapshots

            do {
                _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: .full))
                Issue.record("Changed review was approved")
            } catch let error as NectoBridgeError {
                #expect(error.code == .operationUnavailable)
                #expect(error.message.contains("necto exporter review"))
            }
            await #expect(throws: (any Error).self) { _ = try await coordinator.rejectExporterFromCLI() }
            #expect(try NectoPackageLoader.load(from: path).archive == current.archive)
            #expect(NectoPluginLibrary.installations[id] == currentInstallation)
            #expect(NectoPluginLibrary.grants == currentGrants)
            #expect(await access.policy.snapshot() == currentPolicy)
            #expect(savedSnapshots == currentSnapshots)
            let review = try await coordinator.reviewExporterFromCLI()
            #expect(review["pending"]?.boolValue == (change != .alreadyApproved))
        }
    }

    @Test("CLI approval rejects an unavailable or missing shell choice without applying grants", arguments: [false, true])
    func cliExporterRejectsInvalidShellChoice(hasCommandEnum: Bool) async throws {
        try await withInstallationDirectory { directory in
            let id = "com.example.cli-invalid-shell-\(UUID().uuidString)"
            let plugin = try fixture(
                at: directory.appending(path: id), id: id, operations: [shellOperation(commands: hasCommandEnum ? ["pwd"] : nil)]
            )
            let access = NectoShellAccessController(snapshot: .init()) { _ in Issue.record("Invalid choice saved shell access") }
            let coordinator = cliCoordinator(directory: directory, shellAccess: access)
            let originalGrants = NectoPluginLibrary.grants

            let review = try await coordinator.reviewExporterFromCLI()
            #expect(review["pending"] == true)
            #expect(review["shellAccess"]?["availableChoices"]?.arrayValue?.contains("commands") == hasCommandEnum)
            await #expect(throws: (any Error).self) {
                _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: hasCommandEnum ? nil : .commands))
            }

            #expect(NectoPluginLibrary.installations[id] == nil)
            #expect(NectoPluginLibrary.grants == originalGrants)
            #expect(await access.policy.snapshot() == .init())
            #expect(try NectoPackageLoader.load(from: plugin.rootURL).archive == plugin.archive)
            #expect(try await coordinator.rejectExporterFromCLI()["rejected"] == true)
        }
    }

    @Test("CLI exporter approval cannot interrupt an active UI install")
    func cliExporterRespectsActiveUIInstall() async throws {
        try await withInstallationDirectory { directory in
            let id = "com.example.cli-busy-\(UUID().uuidString)"
            let plugin = try fixture(at: directory.appending(path: id), id: id)
            let coordinator = cliCoordinator(directory: directory)
            #expect(try await coordinator.reviewExporterFromCLI()["pending"] == true)
            coordinator.review(plugin)
            defer { coordinator.cancelInstall() }
            try await waitForApproval(coordinator)

            await #expect(throws: (any Error).self) { _ = try await coordinator.reviewExporterFromCLI() }
            await #expect(throws: (any Error).self) {
                _ = try await coordinator.approveExporterFromCLI(.init(shellAccess: nil))
            }
            await #expect(throws: (any Error).self) { _ = try await coordinator.rejectExporterFromCLI() }
            #expect(coordinator.pendingInstall?.id == id)
            #expect(NectoPluginLibrary.installations[id] == nil)
        }
    }
}
