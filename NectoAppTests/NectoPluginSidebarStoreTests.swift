//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel
import Testing

@Suite("Plugin sidebar storage")
@MainActor
struct NectoPluginSidebarStoreTests {
    private typealias Store = NectoPluginSidebarStore
    private typealias Section = NectoPluginSidebarSection

    @MainActor
    private struct Fixture {
        let suiteName = "necto-sidebar-test-\(UUID())"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        var store: Store { Store(defaults: defaults) }

        func remove() { defaults.removePersistentDomain(forName: suiteName) }
    }

    @Test("Desktop and device trees reload independently with the same IDs and child order")
    func roundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = Section.Folder(name: "Archive", children: [.plugin("unavailable-child")])
        let tools = Section.Folder(name: "Tools", children: [.plugin("shared"), .folder(archive), .plugin("logs")])
        let desktop = try Section(items: [.plugin("desktop"), .folder(tools), .plugin("unavailable-root")])
        let device = try Section(items: [.folder(.init(name: "Device Tools", children: [.plugin("shared")]))])
        try fixture.store.save(desktop, for: .desktop)
        try fixture.store.save(device, for: .device)

        let reopened = Store(defaults: try #require(UserDefaults(suiteName: fixture.suiteName)))
        #expect(try reopened.load(.desktop) == desktop)
        #expect(try reopened.load(.device) == device)
    }

    @Test("Legacy orders migrate once per section with their first occurrence of each ID")
    func migrateOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(["desktop", "shared", "desktop", "unavailable"], forKey: "pluginOrder")
        fixture.defaults.set(["shared", "device", "shared"], forKey: "devicePluginOrder")

        #expect(try fixture.store.load(.desktop).items == [.plugin("desktop"), .plugin("shared"), .plugin("unavailable")])
        #expect(try fixture.store.load(.device).items == [.plugin("shared"), .plugin("device")])
        fixture.defaults.set(["stale-desktop"], forKey: "pluginOrder")
        fixture.defaults.set(["stale-device"], forKey: "devicePluginOrder")

        #expect(try fixture.store.pluginOrder(for: .desktop) == ["desktop", "shared", "unavailable"])
        #expect(try fixture.store.pluginOrder(for: .device) == ["shared", "device"])
    }

    @Test("Missing defaults produce a saved empty section that takes precedence over legacy IDs")
    func emptySections() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.store.load(.desktop).items.isEmpty)
        fixture.defaults.set(["stale-desktop"], forKey: "pluginOrder")
        #expect(try fixture.store.load(.desktop).items.isEmpty)
        #expect(try fixture.store.load(.device).items.isEmpty)
    }

    @Test("Flat reordering persists the requested order and retains unavailable IDs", arguments: [
        NectoPluginSidebarStore.Kind.desktop, .device,
    ])
    func reorderFlatSection(_ kind: NectoPluginSidebarStore.Kind) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = ["a", "unavailable-1", "b", "unavailable-2"]
        fixture.defaults.set(legacy, forKey: kind.legacyOrderKey)

        let expected = ["b", "new", "a", "unavailable-1", "unavailable-2"]
        #expect(try fixture.store.saveFlatOrder(["b", "new", "a"], for: kind) == expected)
        #expect(try fixture.store.pluginOrder(for: kind) == expected)
        #expect(fixture.defaults.stringArray(forKey: kind.legacyOrderKey) == legacy)
    }

    @Test("A nested section still orders plugin rows and rejects a flat reorder")
    func keepNestedOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inner = Section.Folder(name: "Archive", children: [.plugin("unavailable"), .plugin("nested")])
        let outer = Section.Folder(name: "Tools", children: [.folder(inner)])
        let section = try Section(items: [.plugin("top"), .folder(outer), .plugin("tail")])
        try fixture.store.save(section, for: .desktop)
        let original = try #require(fixture.defaults.data(forKey: Store.Kind.desktop.sectionKey))

        let available = [
            plugin(id: "new-zulu", name: "Zulu"), plugin(id: "tail", name: "A"),
            plugin(id: "nested", name: "B"), plugin(id: "new-alpha", name: "Alpha"), plugin(id: "top", name: "C"),
        ]
        let order = try fixture.store.pluginOrder(for: .desktop)
        #expect(NectoPluginLibrary.sorted(available, by: order).map(\.id) == [
            "top", "nested", "tail", "new-alpha", "new-zulu",
        ])
        #expect(throws: Store.StorageError.sectionContainsFolders) {
            try fixture.store.saveFlatOrder(["tail", "nested", "top"], for: .desktop)
        }
        #expect(fixture.defaults.data(forKey: Store.Kind.desktop.sectionKey) == original)
        #expect(try fixture.store.load(.desktop) == section)
    }

    @Test("Malformed data, invariant violations, and a wrong preference type preserve the stored value")
    func keepInvalidSavedSection() throws {
        struct UnvalidatedSection: Encodable {
            let items: [NectoPluginSidebarSection.Item]
        }
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(["legacy"], forKey: "devicePluginOrder")
        let invalidTree = try JSONEncoder().encode(UnvalidatedSection(items: [
            .plugin("duplicate"), .folder(.init(name: "Tools", children: [.plugin("duplicate")])),
        ]))
        let replacement = try Section(items: [.plugin("replacement")])
        let key = Store.Kind.device.sectionKey

        for payload in [Data("invalid JSON".utf8), invalidTree] {
            fixture.defaults.set(payload, forKey: key)
            #expect(throws: Store.StorageError.invalidSavedSection) { try fixture.store.load(.device) }
            #expect(throws: Store.StorageError.invalidSavedSection) {
                try fixture.store.saveFlatOrder(["replacement"], for: .device)
            }
            #expect(throws: Store.StorageError.invalidSavedSection) {
                try fixture.store.save(replacement, for: .device)
            }
            #expect(fixture.defaults.data(forKey: key) == payload)
        }

        fixture.defaults.set("wrong type", forKey: key)
        #expect(throws: Store.StorageError.invalidSavedSection) { try fixture.store.load(.device) }
        #expect(throws: Store.StorageError.invalidSavedSection) {
            try fixture.store.saveFlatOrder(["replacement"], for: .device)
        }
        #expect(fixture.defaults.object(forKey: key) as? String == "wrong type")
    }

    private func plugin(id: String, name: String) -> NectoInstalledPlugin {
        let manifest = NectoPluginManifest(
            id: id, name: name, description: "", version: "1.0.0", author: "Necto tests",
            icon: .init(systemName: "circle"), assets: [], allowedOrigins: [], operations: []
        )
        let archive = NectoPanelArchive(files: [])
        return NectoInstalledPlugin(
            manifest: manifest, rootURL: FileManager.default.temporaryDirectory,
            source: .installed, archive: archive, contentIdentity: archive.contentHash
        )
    }
}
