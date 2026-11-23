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

    @Test("Desktop and device trees reload independently with the same IDs, child order and collapse state")
    func roundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = Section.Folder(name: "Archive", children: [.plugin("unavailable-child")], isCollapsed: true)
        let tools = Section.Folder(name: "Tools", children: [.plugin("shared"), .folder(archive), .plugin("logs")])
        let desktop = try Section(items: [.plugin("desktop"), .folder(tools), .plugin("unavailable-root")])
        let device = try Section(items: [.folder(.init(name: "Device Tools", children: [.plugin("shared")], isCollapsed: true))])
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

        #expect(try fixture.store.load(.desktop).pluginIDs == ["desktop", "shared", "unavailable"])
        #expect(try fixture.store.load(.device).pluginIDs == ["shared", "device"])
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
        #expect(try fixture.store.saveFlatOrder(["b", "new", "a"], for: kind).pluginIDs == expected)
        #expect(try fixture.store.load(kind).pluginIDs == expected)
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
        let order = try fixture.store.load(.desktop).pluginIDs
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

    @Test("A folder edit publishes the saved section and leaves it unchanged on failure")
    func publishAfterSaving() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = NectoPluginSidebarState(store: fixture.store)
        let id = try state.edit(.device) { try $0.createFolder(named: "Tools") }
        try state.edit(.device) { try $0.toggleFolder(id) }
        let original = state[.device]
        #expect(original.items == [.folder(.init(id: id, name: "Tools", isCollapsed: true))])
        #expect(try fixture.store.load(.device) == original)
        #expect(state[.desktop].items.isEmpty)

        #expect(throws: Section.ValidationError.duplicateFolderName) {
            try state.edit(.device) { try $0.createFolder(named: " Tools ") }
        }
        #expect(state[.device] == original)
        #expect(try fixture.store.load(.device) == original)

        let data = Data("malformed".utf8)
        let key = Store.Kind.device.sectionKey
        fixture.defaults.set(data, forKey: key)
        #expect(throws: Store.StorageError.invalidSavedSection) {
            try state.edit(.device) { try $0.createFolder(named: "Archive", in: id) }
        }
        #expect(state[.device] == original)
        #expect(fixture.defaults.data(forKey: key) == data)
        #expect(!state.saveFlatOrder(["replacement"], for: .device))
        #expect(state[.device] == original)
    }

    @Test("Child creation opens its saved ancestors and deletion preserves surviving folders' collapse state")
    func persistCollapseState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let child = Section.Folder(name: "Archive", isCollapsed: true)
        let parent = Section.Folder(name: "Tools", children: [.folder(child)], isCollapsed: true)
        let other = Section.Folder(name: "Logs", isCollapsed: true)
        let section = try Section(items: [.folder(parent), .folder(other)])
        try fixture.store.save(section, for: .desktop)
        let state = NectoPluginSidebarState(store: fixture.store)
        #expect(state[.desktop] == section)

        let id = try state.edit(.desktop) { try $0.createFolder(defaultName: "New Folder", in: child.id) }
        let created = Section.Folder(id: id, name: "New Folder")
        var expandedChild = child
        expandedChild.children = [.folder(created)]
        expandedChild.isCollapsed = false
        var expandedParent = parent
        expandedParent.children = [.folder(expandedChild)]
        expandedParent.isCollapsed = false
        #expect(state[.desktop].items == [.folder(expandedParent), .folder(other)])
        #expect(state[.desktop].visibleRows(activePluginIDs: [], disabledPluginIDs: []).map(\.id) == [
            .folder(parent.id), .folder(child.id), .folder(id), .folder(other.id),
        ])

        try state.edit(.desktop) { try $0.toggleFolder(child.id) }
        try state.edit(.desktop) { try $0.toggleFolder(parent.id) }
        var collapsedChild = child
        collapsedChild.children = [.folder(created)]
        var collapsedParent = parent
        collapsedParent.children = [.folder(collapsedChild)]
        let reloaded = NectoPluginSidebarState(store: fixture.store)
        #expect(reloaded[.desktop].items == [.folder(collapsedParent), .folder(other)])
        try reloaded.edit(.desktop) { try $0.deleteFolder(parent.id) }
        #expect(reloaded[.desktop].items == [.folder(collapsedChild), .folder(other)])
        #expect(try fixture.store.load(.desktop) == reloaded[.desktop])
    }

    @Test("Saved sections without collapse state open their folders")
    func readPreviousFormat() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folderID = UUID()
        let data = Data("""
        {"items":[{"folder":{"_0":{
            "id":"\(folderID.uuidString)","name":"Archive","children":[{"plugin":{"_0":"sample"}}]
        }}}]}
        """.utf8)
        fixture.defaults.set(data, forKey: Store.Kind.desktop.sectionKey)

        let section = try fixture.store.load(.desktop)
        #expect(section.items == [.folder(.init(id: folderID, name: "Archive", children: [.plugin("sample")]))])
        #expect(section.visibleRows(activePluginIDs: ["sample"], disabledPluginIDs: []).map(\.id) == [
            .folder(folderID), .plugin("sample"),
        ])
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
