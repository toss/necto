//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

private struct CheckFailed: Error { let message: String }

@main
@MainActor
struct DevicePluginStoreChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailed(message: message) }
    }

    static func rejects(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { return }
        throw CheckFailed(message: "Invalid panel was accepted")
    }

    static func archive(id: String = "com.example.cache", text: String = "original") throws -> NectoPanelArchive {
        let manifest = NectoPluginManifest(
            id: id, name: "Cache test", description: "Cache verification", version: "1.0.0",
            author: "Necto tests", icon: .init(systemName: "square"), assets: ["index.html"],
            allowedOrigins: ["self"], operations: [.init(
                id: "host.info", title: "Host", description: "Host information", kind: .once,
                binding: .init(name: "necto.desktop.host.info", version: 1),
                inputSchema: .object([:]), outputSchema: .object([:]), timeoutMs: 1000
            )]
        )
        return NectoPanelArchive(files: [
            .init(path: "manifest.json", data: try JSONEncoder().encode(manifest)),
            .init(path: "index.html", data: Data(text.utf8)),
        ])
    }

    static func main() async throws {
        guard let sandbox = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw CheckFailed(message: "An isolated CFFIXED_USER_HOME is required")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try require(
            support.resolvingSymlinksInPath().path.hasPrefix(URL(filePath: sandbox).resolvingSymlinksInPath().path + "/"),
            "Refusing to access the user's Application Support directory"
        )
        let store = NectoDevicePluginStore()
        let original = try archive()
        var fetches = 0
        func load(_ stamp: NectoPanelStamp, bundleID: String = "com.example.first") async throws -> NectoInstalledPlugin {
            try await store.plugin(pluginID: "com.example.cache", stamp: stamp, appName: "Test", appBundleID: bundleID) {
                fetches += 1
                return original
            }
        }

        let first = try await load(original.stamp)
        try require(fetches == 1 && first.archive == original, "Initial fetch must load the verified bytes")
        _ = try await load(original.stamp)
        try require(fetches == 1, "A verified cache should be reused")
        print("PASS initial fetch and verified cache reuse")

        let index = first.rootURL.appending(path: "index.html")
        try Data("tampered".utf8).write(to: index)
        let repaired = try await load(original.stamp)
        try require(fetches == 2 && repaired.archive == original, "Tampered cache must be fetched and replaced")
        try require(try NectoPanelArchive.read(directory: first.rootURL) == original, "Replacement must repair the disk cache")
        print("PASS tampered cache replacement")

        let otherApp = try await load(original.stamp, bundleID: "com.example.second")
        try require(first.principal != otherApp.principal, "Shared bytes must not share app permissions")
        print("PASS device principal separation")

        let legacy = NectoPanelStamp(hash: original.legacyContentHash)
        let legacyFirst = try await load(legacy)
        _ = try await load(legacy)
        try require(fetches == 4, "Legacy stamps must fetch on every registration")
        try require(legacyFirst.rootURL.lastPathComponent == original.contentHash, "Legacy fetch must use an unambiguous cache key")
        print("PASS legacy stamps fetch instead of trusting a legacy cache")

        let changed = try archive(text: "updated")
        try await rejects {
            _ = try await store.plugin(pluginID: first.id, stamp: changed.stamp, appName: "Test", appBundleID: "com.example.first") { original }
        }
        try require(try NectoPanelArchive.read(directory: first.rootURL) == original, "A hash mismatch must preserve the previous cache")
        print("PASS mismatched fetch preserves previous cache")

        let wrongID = try archive(id: "com.example.other")
        try await rejects {
            _ = try await store.plugin(pluginID: first.id, stamp: wrongID.stamp, appName: "Test", appBundleID: "com.example.first") { wrongID }
        }
        try require(!FileManager.default.fileExists(atPath: first.rootURL.deletingLastPathComponent().appending(path: wrongID.contentHash).path), "Wrong manifest ID must not be installed")
        print("PASS mismatched manifest ID is not installed")

        for invalidID in ["..", ".", "../outside", "a/b"] {
            var fetched = false
            try await rejects {
                _ = try await store.plugin(pluginID: invalidID, stamp: original.stamp, appName: "Test", appBundleID: "com.example.first") {
                    fetched = true
                    return original
                }
            }
            try require(!fetched, "Invalid identifiers must fail before fetching")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: first.rootURL.deletingLastPathComponent().path)
        try require(!leftovers.contains { $0.hasPrefix(".necto-") }, "Staging and backup directories must be removed")
        print("PASS invalid paths and temporary directory cleanup")
    }
}
