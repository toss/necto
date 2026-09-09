//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing

@Suite("Device panel cache")
@MainActor
struct NectoDevicePluginStoreTests {
    private func archive(id: String = "com.example.cache", text: String = "original") throws -> NectoPanelArchive {
        let manifest = NectoPluginManifest(
            id: id, name: "Cache test", description: "Cache verification", version: "1.0.0",
            author: "Necto tests", icon: .init(systemName: "square"), assets: ["index.html"],
            allowedOrigins: ["self"], operations: []
        )
        return NectoPanelArchive(files: [
            .init(path: "manifest.json", data: try JSONEncoder().encode(manifest)),
            .init(path: "index.html", data: Data(text.utf8)),
        ])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "necto-cache-test-\(UUID().uuidString)")
    }

    @Test("Reuses verified bytes, repairs tampering, and keeps app principals separate")
    func verifiedCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NectoDevicePluginStore(directory: directory)
        let original = try archive()
        var fetches = 0
        func load(bundleID: String = "com.example.first") async throws -> NectoInstalledPlugin {
            try await store.plugin(pluginID: "com.example.cache", stamp: original.stamp,
                                   appName: "Test", appBundleID: bundleID) {
                fetches += 1
                return original
            }
        }

        let first = try await load()
        #expect(fetches == 1)
        #expect(first.archive == original)
        _ = try await load()
        #expect(fetches == 1)

        try Data("tampered".utf8).write(to: first.rootURL.appending(path: "index.html"))
        let repaired = try await load()
        #expect(fetches == 2)
        #expect(repaired.archive == original)
        #expect(try NectoPanelArchive.read(directory: first.rootURL) == original)

        let otherApp = try await load(bundleID: "com.example.second")
        #expect(first.principal != otherApp.principal)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: first.rootURL.deletingLastPathComponent().path)
        #expect(!leftovers.contains { $0.hasPrefix(".necto-") })
    }

    @Test("Legacy stamps fetch each registration and use the verified content hash")
    func legacyStamps() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NectoDevicePluginStore(directory: directory)
        let original = try archive()
        var fetches = 0
        for _ in 0..<2 {
            let plugin = try await store.plugin(
                pluginID: "com.example.cache", stamp: .init(hash: original.legacyContentHash),
                appName: "Test", appBundleID: "com.example.first"
            ) {
                fetches += 1
                return original
            }
            #expect(plugin.rootURL.lastPathComponent == original.contentHash)
        }
        #expect(fetches == 2)
    }

    @Test("Mismatched hashes and manifest IDs preserve the previous cache")
    func rejectsMismatches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NectoDevicePluginStore(directory: directory)
        let original = try archive()
        let first = try await store.plugin(pluginID: "com.example.cache", stamp: original.stamp,
                                           appName: "Test", appBundleID: "com.example.first") { original }
        let changed = try archive(text: "updated")
        await #expect(throws: NectoDevicePluginError.self) {
            _ = try await store.plugin(pluginID: first.id, stamp: changed.stamp,
                                       appName: "Test", appBundleID: "com.example.first") { original }
        }
        let wrongID = try archive(id: "com.example.other")
        await #expect(throws: NectoDevicePluginError.self) {
            _ = try await store.plugin(pluginID: first.id, stamp: wrongID.stamp,
                                       appName: "Test", appBundleID: "com.example.first") { wrongID }
        }
        #expect(try NectoPanelArchive.read(directory: first.rootURL) == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: first.rootURL.deletingLastPathComponent().path)
        #expect(!leftovers.contains(wrongID.contentHash))
        #expect(!leftovers.contains { $0.hasPrefix(".necto-") })
    }

    @Test("Invalid IDs fail before fetching or creating a cache", arguments: ["..", ".", "../outside", "a/b"])
    func rejectsInvalidPaths(id: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NectoDevicePluginStore(directory: directory)
        let original = try archive()
        var fetched = false
        await #expect(throws: NectoDevicePluginError.self) {
            _ = try await store.plugin(pluginID: id, stamp: original.stamp,
                                       appName: "Test", appBundleID: "com.example.first") {
                fetched = true
                return original
            }
        }
        #expect(!fetched)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
