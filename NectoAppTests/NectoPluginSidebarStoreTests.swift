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

    @Test("Reordering new root plugins preserves other unplaced and unavailable siblings", arguments: [
        NectoPluginSidebarStore.Kind.desktop, .device,
    ])
    func reorderFlatSection(_ kind: NectoPluginSidebarStore.Kind) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = ["a", "unavailable-1", "b", "unavailable-2"]
        fixture.defaults.set(legacy, forKey: kind.legacyOrderKey)

        let state = NectoPluginSidebarState(store: fixture.store)
        let active = ["a", "b", "new-a", "new-b", "new-c"]
        #expect(state.reorder(
            location(.plugin("new-c"), in: kind), relativeTo: location(.plugin("new-b"), in: kind),
            position: .before, activePluginIDs: active, disabledPluginIDs: []
        ))
        let expected = ["a", "unavailable-1", "b", "unavailable-2", "new-a", "new-c", "new-b"]
        #expect(state[kind].pluginIDs == expected)
        #expect(try fixture.store.load(kind).pluginIDs == expected)
        #expect(fixture.defaults.stringArray(forKey: kind.legacyOrderKey) == legacy)
    }

    @Test("A root reorder preserves nested ownership and unavailable descendants")
    func keepNestedOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inner = Section.Folder(name: "Archive", children: [.plugin("unavailable"), .plugin("nested")])
        let outer = Section.Folder(name: "Tools", children: [.folder(inner)])
        let section = try Section(items: [.plugin("top"), .folder(outer), .plugin("tail")])
        try fixture.store.save(section, for: .desktop)

        let available = [
            plugin(id: "new-zulu", name: "Zulu"), plugin(id: "tail", name: "A"),
            plugin(id: "nested", name: "B"), plugin(id: "new-alpha", name: "Alpha"), plugin(id: "top", name: "C"),
        ]
        let order = try fixture.store.load(.desktop).pluginIDs
        #expect(NectoPluginLibrary.sorted(available, by: order).map(\.id) == [
            "top", "nested", "tail", "new-alpha", "new-zulu",
        ])
        let state = NectoPluginSidebarState(store: fixture.store)
        #expect(state.reorder(
            location(.plugin("tail"), in: .desktop), relativeTo: location(.plugin("top"), in: .desktop),
            position: .before, activePluginIDs: available.map(\.id), disabledPluginIDs: []
        ))
        let expected: [Section.Item] = [
            .plugin("tail"), .plugin("top"), .folder(outer), .plugin("new-zulu"), .plugin("new-alpha"),
        ]
        #expect(state[.desktop].items == expected)
        #expect(try fixture.store.load(.desktop).items == expected)
    }

    @Test("Malformed data, invariant violations, and a wrong preference type preserve the stored value")
    func keepInvalidSavedSection() throws {
        struct UnvalidatedSection: Encodable {
            let items: [NectoPluginSidebarSection.Item]
        }
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(["legacy"], forKey: "devicePluginOrder")
        let state = NectoPluginSidebarState(store: fixture.store)
        let original = state[.device]
        let invalidTree = try JSONEncoder().encode(UnvalidatedSection(items: [
            .plugin("duplicate"), .folder(.init(name: "Tools", children: [.plugin("duplicate")])),
        ]))
        let replacement = try Section(items: [.plugin("replacement")])
        let key = Store.Kind.device.sectionKey

        for payload in [Data("invalid JSON".utf8), invalidTree] {
            fixture.defaults.set(payload, forKey: key)
            #expect(throws: Store.StorageError.invalidSavedSection) { try fixture.store.load(.device) }
            #expect(!state.reorder(
                location(.plugin("b")), relativeTo: location(.plugin("a")), position: .before,
                activePluginIDs: ["a", "b"], disabledPluginIDs: []
            ))
            #expect(throws: Store.StorageError.invalidSavedSection) {
                try fixture.store.save(replacement, for: .device)
            }
            #expect(fixture.defaults.data(forKey: key) == payload)
            #expect(state[.device] == original)
        }

        fixture.defaults.set("wrong type", forKey: key)
        #expect(throws: Store.StorageError.invalidSavedSection) { try fixture.store.load(.device) }
        #expect(!state.reorder(
            location(.plugin("b")), relativeTo: location(.plugin("a")), position: .before,
            activePluginIDs: ["a", "b"], disabledPluginIDs: []
        ))
        #expect(fixture.defaults.object(forKey: key) as? String == "wrong type")
        #expect(state[.device] == original)
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
    }

    @Test("A disabled plugin can reorder among its saved siblings while root disabled rows stay in place")
    func reorderNestedDisabledPlugin() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = Section.Folder(name: "Tools", children: [.plugin("a"), .plugin("hidden"), .plugin("disabled")])
        let section = try Section(items: [.plugin("root-disabled"), .folder(folder), .plugin("tail")])
        try fixture.store.save(section, for: .device)
        let state = NectoPluginSidebarState(store: fixture.store)
        let rootDisabled = location(.plugin("root-disabled"))
        let tail = location(.plugin("tail"))
        let active = ["a", "tail"]
        let disabled = ["disabled", "root-disabled"]

        #expect(!state.reorder(rootDisabled, relativeTo: tail, position: .after, activePluginIDs: active, disabledPluginIDs: disabled))
        #expect(!state.reorder(tail, relativeTo: rootDisabled, position: .after, activePluginIDs: active, disabledPluginIDs: disabled))
        #expect(state.reorder(
            location(.plugin("disabled"), parentID: folder.id), relativeTo: location(.plugin("a"), parentID: folder.id),
            position: .before, activePluginIDs: active, disabledPluginIDs: disabled
        ))
        var expectedFolder = folder
        expectedFolder.children = [.plugin("disabled"), .plugin("a"), .plugin("hidden")]
        #expect(try fixture.store.load(.device).items == [.plugin("root-disabled"), .folder(expectedFolder), .plugin("tail")])
    }

    @Test("A drop whose source or destination is hidden, dimmed or in another section leaves storage unchanged")
    func refuseUnavailableAndCrossSectionDrops() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = Section.Folder(name: "Tools", children: [.plugin("nested")])
        let section = try Section(items: [.plugin("a"), .plugin("b"), .folder(folder)])
        try fixture.store.save(section, for: .device)
        try fixture.store.save(section, for: .desktop)
        let state = NectoPluginSidebarState(store: fixture.store)
        let original = try #require(fixture.defaults.data(forKey: Store.Kind.device.sectionKey))
        let a = location(.plugin("a"))
        let b = location(.plugin("b"))
        let tools = location(.folder(folder.id))
        let absent = location(.plugin("absent"))

        #expect(!state.reorder(a, relativeTo: b, position: .after, activePluginIDs: ["b"], disabledPluginIDs: []))
        #expect(!state.reorder(b, relativeTo: absent, position: .after, activePluginIDs: ["b"], disabledPluginIDs: []))
        #expect(!state.reorder(tools, relativeTo: b, position: .before, activePluginIDs: ["a", "b"], disabledPluginIDs: []))
        #expect(!state.reorder(b, relativeTo: tools, position: .after, activePluginIDs: ["a", "b"], disabledPluginIDs: []))
        #expect(!state.reorder(
            b, relativeTo: location(.plugin("a"), in: .desktop), position: .before,
            activePluginIDs: ["a", "b"], disabledPluginIDs: []
        ))
        #expect(state[.device] == section)
        #expect(state[.desktop] == section)
        #expect(fixture.defaults.data(forKey: Store.Kind.device.sectionKey) == original)
    }

    @Test("A drop rechecks the saved parent and cancels when the source has moved")
    func refuseStaleParentDrop() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let left = Section.Folder(name: "Left", children: [.plugin("a"), .plugin("b")])
        let right = Section.Folder(name: "Right")
        let before = try Section(items: [.folder(left), .folder(right)])
        try fixture.store.save(before, for: .device)
        let state = NectoPluginSidebarState(store: fixture.store)

        var newLeft = left
        newLeft.children = [.plugin("b")]
        var newRight = right
        newRight.children = [.plugin("a")]
        let latest = try Section(items: [.folder(newLeft), .folder(newRight)])
        try fixture.store.save(latest, for: .device)
        let original = try #require(fixture.defaults.data(forKey: Store.Kind.device.sectionKey))

        #expect(!state.reorder(
            location(.plugin("a"), parentID: left.id), relativeTo: location(.plugin("b"), parentID: left.id),
            position: .after, activePluginIDs: ["a", "b"], disabledPluginIDs: []
        ))
        #expect(state[.device] == before)
        #expect(fixture.defaults.data(forKey: Store.Kind.device.sectionKey) == original)
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

    @Test("Disabling a nested desktop plugin keeps its folders and re-enabling it lists it at the root")
    func detachDisabledDesktopPlugin() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inspector = plugin(id: "inspector", name: "Inspector")
        let deepest = Section.Folder(name: "Utilities", children: [.plugin(inspector.id)], isCollapsed: true)
        let middle = Section.Folder(name: "Tools", children: [.folder(deepest)])
        let sibling = Section.Folder(name: "Archive", isCollapsed: true)
        let outer = Section.Folder(name: "Workspace", children: [.folder(middle), .folder(sibling)], isCollapsed: true)
        let original = try Section(items: [.plugin("before"), .folder(outer), .plugin("after")])
        try fixture.store.save(original, for: .desktop)
        let state = NectoPluginSidebarState(store: fixture.store)

        #expect(try state.setEnabled(inspector, enabled: false) == [inspector.id])
        #expect(fixture.defaults.stringArray(forKey: "disabledPluginIDs") == [inspector.id])
        var empty = deepest
        empty.children = []
        var updatedMiddle = middle
        updatedMiddle.children = [.folder(empty)]
        var updatedOuter = outer
        updatedOuter.children = [.folder(updatedMiddle), .folder(sibling)]
        let detached: [Section.Item] = [.plugin("before"), .folder(updatedOuter), .plugin("after"), .plugin(inspector.id)]
        #expect(state[.desktop].items == detached)
        #expect(try fixture.store.load(.desktop).items == detached)
        let whileDisabled = state[.desktop].visibleRows(activePluginIDs: ["before", "after"], disabledPluginIDs: [])
        #expect(whileDisabled.map(\.id) == [.plugin("before"), .folder(outer.id), .plugin("after")])
        #expect(whileDisabled.allSatisfy { !$0.isDimmed })

        let enabled = try state.setEnabled(inspector, enabled: true)
        #expect(enabled.isEmpty)
        #expect(state[.desktop].items == detached)
        let catalog = [inspector, plugin(id: "after", name: "After"), plugin(id: "before", name: "Before")]
        let sorted = NectoPluginLibrary.sorted(catalog, by: state[.desktop].pluginIDs).map(\.id)
        #expect(sorted == ["before", "after", inspector.id])
        let afterEnable = state[.desktop].visibleRows(activePluginIDs: sorted, disabledPluginIDs: [])
        #expect(afterEnable.last?.id == .plugin(inspector.id))
        #expect(afterEnable.last?.depth == 1)
    }

    @Test("Disabling a desktop plugin already at the root preserves its stored placement")
    func keepDesktopRootPlacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = plugin(id: "root", name: "Root")
        let state = NectoPluginSidebarState(store: fixture.store)
        let latest = try Section(items: [.plugin(root.id), .plugin("tail")])
        try fixture.store.save(latest, for: .desktop)
        let key = Store.Kind.desktop.sectionKey
        let original = try #require(fixture.defaults.data(forKey: key))

        #expect(try state.setEnabled(root, enabled: false) == [root.id])
        #expect(try state.setEnabled(root, enabled: true).isEmpty)
        #expect(fixture.defaults.data(forKey: key) == original)
        #expect(state[.desktop] == latest)
    }

    @Test("Device disablement and re-enabling preserve both sections and recompute the folder state")
    func retainDeviceMembership() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let device = plugin(id: "stream", name: "Stream", source: .device(appName: "Example", appBundleID: "com.example.app"))
        let deviceFolder = Section.Folder(name: "Capture", children: [.plugin(device.id)])
        let desktopFolder = Section.Folder(name: "Tools", children: [.plugin(device.id)])
        let deviceSection = try Section(items: [.folder(deviceFolder), .plugin("tail")])
        let desktopSection = try Section(items: [.folder(desktopFolder)])
        try fixture.store.save(deviceSection, for: .device)
        try fixture.store.save(desktopSection, for: .desktop)
        let state = NectoPluginSidebarState(store: fixture.store)

        #expect(try state.setEnabled(device, enabled: false) == [device.id])
        let disabled = state[.device].visibleRows(activePluginIDs: ["tail"], disabledPluginIDs: [device.id])
        #expect(disabled.map(\.id) == [.plugin("tail"), .folder(deviceFolder.id), .plugin(device.id)])
        #expect(disabled.filter(\.isDimmed).map(\.id) == [.folder(deviceFolder.id), .plugin(device.id)])
        let unavailable = state[.device].visibleRows(activePluginIDs: ["tail"], disabledPluginIDs: [])
        #expect(unavailable.map(\.id) == [.plugin("tail"), .folder(deviceFolder.id)])
        #expect(unavailable.last?.isDimmed == true)

        #expect(try state.setEnabled(device, enabled: true).isEmpty)
        let reenabled = state[.device].visibleRows(activePluginIDs: [device.id, "tail"], disabledPluginIDs: [])
        #expect(reenabled.map(\.id) == [.folder(deviceFolder.id), .plugin(device.id), .plugin("tail")])
        #expect(reenabled.allSatisfy { !$0.isDimmed })
        #expect(state[.device] == deviceSection)
        #expect(state[.desktop] == desktopSection)
        #expect(try fixture.store.load(.device) == deviceSection)
        #expect(try fixture.store.load(.desktop) == desktopSection)
    }

    @Test("A corrupt saved desktop section stops a disable before it changes enablement")
    func keepEnablementOnFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = NectoPluginSidebarState(store: fixture.store)
        let original = state[.desktop]
        let corrupt = Data("invalid".utf8)
        let key = Store.Kind.desktop.sectionKey
        fixture.defaults.set(corrupt, forKey: key)
        fixture.defaults.set(["already-disabled"], forKey: "disabledPluginIDs")

        let inspector = plugin(id: "inspector", name: "Inspector")
        #expect(throws: Store.StorageError.invalidSavedSection) {
            try state.setEnabled(inspector, enabled: false)
        }
        #expect(state[.desktop] == original)
        #expect(fixture.defaults.data(forKey: key) == corrupt)
        #expect(fixture.defaults.stringArray(forKey: "disabledPluginIDs") == ["already-disabled"])
    }

    private func location(
        _ id: Section.Item.ID,
        in kind: Store.Kind = .device,
        parentID: UUID? = nil
    ) -> NectoPluginSidebarState.ItemLocation {
        .init(kind: kind, id: id, parentID: parentID)
    }

    private func plugin(id: String, name: String, source: NectoInstalledPlugin.Source = .installed) -> NectoInstalledPlugin {
        let manifest = NectoPluginManifest(
            id: id, name: name, description: "", version: "1.0.0", author: "Necto tests",
            icon: .init(systemName: "circle"), assets: [], allowedOrigins: [], operations: []
        )
        let archive = NectoPanelArchive(files: [])
        return NectoInstalledPlugin(
            manifest: manifest, rootURL: FileManager.default.temporaryDirectory,
            source: source, archive: archive, contentIdentity: archive.contentHash
        )
    }
}
