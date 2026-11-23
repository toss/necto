//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@Suite("Plugin sidebar section")
struct NectoPluginSidebarSectionTests {
    typealias Section = NectoPluginSidebarSection
    typealias Folder = Section.Folder
    typealias Item = Section.Item

    @Test("Moving either visible row around a hidden sibling keeps the hidden sibling's position relative to the untouched row")
    func insertAroundHiddenSibling() throws {
        let saved = try Section(items: [.plugin("a"), .plugin("c"), .plugin("b")])
        let rows = saved.visibleRows(activePluginIDs: ["a", "b"], disabledPluginIDs: [])
        var bBeforeA = saved
        let upward = try #require(Section.insertion(from: [1], to: 0, in: rows))
        #expect(try bBeforeA.reorder(
            upward.source.id, relativeTo: upward.anchor.id, position: upward.position, in: upward.source.parentID
        ))
        #expect(bBeforeA.pluginIDs == ["b", "a", "c"])

        var aAfterB = saved
        let downward = try #require(Section.insertion(from: [0], to: rows.count, in: rows))
        #expect(try aAfterB.reorder(
            downward.source.id, relativeTo: downward.anchor.id, position: downward.position, in: downward.source.parentID
        ))
        #expect(aAfterB.pluginIDs == ["c", "b", "a"])
    }

    @Test("A native insertion after an expanded folder lands beyond its subtree")
    func insertAfterExpandedFolder() throws {
        let child = Folder(name: "Child", children: [.plugin("child")])
        let folder = Folder(name: "Tools", children: [.plugin("tool"), .folder(child)])
        let unavailable = Folder(name: "Unavailable", children: [.plugin("missing")])
        var section = try Section(items: [.plugin("a"), .folder(folder), .plugin("disabled"), .folder(unavailable)])
        let rows = section.visibleRows(activePluginIDs: ["a", "child", "tool"], disabledPluginIDs: ["disabled"])
        #expect(rows.map(\.id) == [
            .plugin("a"), .folder(folder.id), .plugin("tool"), .folder(child.id), .plugin("child"),
            .plugin("disabled"), .folder(unavailable.id),
        ])

        #expect(Section.insertion(from: [0], to: 2, in: rows) == nil) // Inside Tools.
        #expect(Section.insertion(from: [1], to: 5, in: rows) == nil) // After its own subtree.
        #expect(Section.insertion(from: [2], to: 0, in: rows) == nil) // Outside Tools.
        #expect(Section.insertion(from: [0], to: 6, in: rows) == nil) // After root disabled.
        #expect(Section.insertion(from: [0], to: 7, in: rows) == nil) // After dimmed folder.
        #expect(Section.insertion(from: [6], to: 0, in: rows) == nil) // Dimmed source.
        #expect(Section.insertion(from: [0, 1], to: 5, in: rows) == nil)
        #expect(Section.insertion(from: [7], to: 0, in: rows) == nil)
        #expect(Section.insertion(from: [0], to: 8, in: rows) == nil)

        let move = try #require(Section.insertion(from: [0], to: 5, in: rows))
        #expect(try section.reorder(
            move.source.id, relativeTo: move.anchor.id, position: move.position, in: move.source.parentID
        ))
        #expect(section.items == [.folder(folder), .plugin("a"), .plugin("disabled"), .folder(unavailable)])
    }

    @Test("Reordering a nested folder moves its entire subtree within the same parent")
    func reorderNestedFolder() throws {
        let dimmedChild = Folder(name: "Unavailable", children: [.plugin("unavailable")], isCollapsed: true)
        let source = Folder(name: "Tools", children: [.folder(dimmedChild), .plugin("tool")], isCollapsed: true)
        let sibling = Folder(name: "Other")
        let parent = Folder(name: "Parent", children: [.folder(source), .plugin("hidden"), .folder(sibling)])
        var section = try Section(items: [.plugin("root"), .folder(parent)])
        #expect(try section.reorder(.folder(source.id), relativeTo: .folder(sibling.id), position: .after, in: parent.id))
        var updatedParent = parent
        updatedParent.children = [.plugin("hidden"), .folder(sibling), .folder(source)]
        #expect(section.items == [.plugin("root"), .folder(updatedParent)])

        let original = section
        #expect(try !section.reorder(.folder(source.id), relativeTo: .plugin("root"), position: .before, in: parent.id))
        #expect(try !section.reorder(.folder(source.id), relativeTo: .folder(source.id), position: .before, in: parent.id))
        #expect(section == original)
    }

    @Test("Default folder names use the first free suffix only within the requested parent")
    func createDefaultFolders() throws {
        let first = Folder(name: "New Folder")
        let third = Folder(name: "New Folder(2)")
        var section = try Section(items: [.folder(first), .folder(third)])
        let second = try section.createFolder(defaultName: "New Folder")
        let fourth = try section.createFolder(defaultName: "New Folder")
        let child = try section.createFolder(defaultName: "New Folder", in: first.id)
        #expect(section.items == [
            .folder(.init(id: first.id, name: first.name, children: [.folder(.init(id: child, name: "New Folder"))])),
            .folder(third),
            .folder(.init(id: second, name: "New Folder(1)")),
            .folder(.init(id: fourth, name: "New Folder(3)")),
        ])
    }

    @Test("Folders keep sections visible and unavailable plugins stay hidden")
    func visibleRows() throws {
        let flat = try Section(items: [.plugin("unavailable")])
        #expect(flat.isVisible(hasAvailablePlugins: false) == false)
        #expect(flat.isVisible(hasAvailablePlugins: true))

        let empty = Folder(name: "Empty")
        let tools = Folder(name: "Tools", children: [
            .plugin("nested"), .plugin("nested-disabled"), .plugin("unavailable"),
        ])
        var section = try Section(items: [.plugin("root-disabled"), .folder(tools), .folder(empty)])
        #expect(section.isVisible(hasAvailablePlugins: false))
        #expect(section.visibleRows(activePluginIDs: [], disabledPluginIDs: []).map(\.id) == [
            .folder(empty.id), .folder(tools.id),
        ])

        let active = ["nested", "unplaced"]
        let disabled = ["root-disabled", "nested-disabled"]
        #expect(section.visibleRows(activePluginIDs: active, disabledPluginIDs: disabled).map(\.id) == [
            .folder(tools.id), .plugin("nested"), .plugin("nested-disabled"), .folder(empty.id),
            .plugin("unplaced"), .plugin("root-disabled"),
        ])
        try section.toggleFolder(tools.id)
        #expect(section.visibleRows(activePluginIDs: active, disabledPluginIDs: disabled).map(\.id) == [
            .folder(tools.id), .folder(empty.id), .plugin("unplaced"), .plugin("root-disabled"),
        ])
    }

    @Test("A parent's dimmed folders sink in that parent and return to their saved position as availability changes")
    func nestedFolderAvailability() throws {
        let appBTools = Folder(name: "App B Tools", children: [.plugin("app-b")])
        let unavailable = Folder(name: "Unavailable", children: [.plugin("hidden")])
        let empty = Folder(name: "Empty")
        let appATools = Folder(name: "App A Tools", children: [.plugin("app-a")], isCollapsed: true)
        let parent = Folder(name: "Tools", children: [
            .folder(appBTools), .plugin("disabled"), .folder(unavailable), .folder(empty), .folder(appATools),
        ])
        var section = try Section(items: [.folder(parent), .plugin("tail")])
        let saved = section

        let appA = section.visibleRows(activePluginIDs: ["app-a", "tail"], disabledPluginIDs: ["disabled"])
        #expect(appA.map(\.id) == [
            .folder(parent.id), .plugin("disabled"), .folder(empty.id), .folder(appATools.id), .folder(appBTools.id),
            .folder(unavailable.id), .plugin("tail"),
        ])
        #expect(appA.filter(\.isDimmed).map(\.id) == [.plugin("disabled"), .folder(appBTools.id), .folder(unavailable.id)])
        #expect(appA.map(\.depth) == [1, 2, 2, 2, 2, 2, 1])

        let appB = section.visibleRows(activePluginIDs: ["app-b", "tail"], disabledPluginIDs: ["disabled"])
        #expect(appB.map(\.id) == [
            .folder(parent.id), .folder(appBTools.id), .plugin("app-b"), .plugin("disabled"), .folder(empty.id),
            .folder(unavailable.id), .folder(appATools.id), .plugin("tail"),
        ])
        #expect(appB.filter(\.isDimmed).map(\.id) == [.plugin("disabled"), .folder(unavailable.id), .folder(appATools.id)])
        #expect(section == saved)

        try section.toggleFolder(parent.id)
        let collapsed = section.visibleRows(activePluginIDs: ["app-a", "tail"], disabledPluginIDs: ["disabled"])
        #expect(collapsed.map(\.id) == [.folder(parent.id), .plugin("tail")])
        #expect(collapsed.allSatisfy { !$0.isDimmed })
    }

    @Test("Root disabled rows follow normal rows and fallbacks before dimmed folders")
    func rootDisabledArea() throws {
        let unavailable = Folder(name: "Unavailable", children: [.plugin("hidden")])
        let disabled = Folder(name: "Disabled", children: [.plugin("nested-disabled")])
        let empty = Folder(name: "Empty")
        let emptyStack = Folder(name: "Empty Stack", children: [.folder(empty)])
        let section = try Section(items: [
            .folder(unavailable), .plugin("root-disabled-z"), .folder(emptyStack), .plugin("root-active"),
            .folder(disabled), .plugin("root-disabled-a"), .plugin("unavailable-disabled"),
        ])
        let rows = section.visibleRows(
            activePluginIDs: ["unplaced-active", "root-active"],
            disabledPluginIDs: ["root-disabled-a", "unplaced-disabled", "root-disabled-z", "nested-disabled"]
        )
        #expect(rows.map(\.id) == [
            .folder(emptyStack.id), .folder(empty.id), .plugin("root-active"), .plugin("unplaced-active"),
            .plugin("root-disabled-a"), .plugin("unplaced-disabled"), .plugin("root-disabled-z"),
            .folder(unavailable.id), .folder(disabled.id), .plugin("nested-disabled"),
        ])
        #expect(rows.filter(\.isDimmed).map(\.id) == [
            .plugin("root-disabled-a"), .plugin("unplaced-disabled"), .plugin("root-disabled-z"),
            .folder(unavailable.id), .folder(disabled.id), .plugin("nested-disabled"),
        ])
        #expect(rows.last?.depth == 2)
    }

    @Test("Creating folders appends within the requested parent and trims names")
    func createFolders() throws {
        let existing = Folder(name: "Existing", children: [.plugin("b")])
        var section = try Section(items: [.plugin("a"), .folder(existing)])
        let root = try section.createFolder(named: " Tools \n")
        let child = try section.createFolder(named: " Logs ", in: existing.id)
        let grandchild = try section.createFolder(named: " Debug ", in: child)
        #expect(section.items == [
            .plugin("a"),
            .folder(.init(id: existing.id, name: "Existing", children: [
                .plugin("b"),
                .folder(.init(id: child, name: "Logs", children: [
                    .folder(.init(id: grandchild, name: "Debug")),
                ])),
            ])),
            .folder(.init(id: root, name: "Tools")),
        ])
    }

    @Test("A folder at depth three can contain plugins but cannot contain another folder")
    func limitFolderDepth() throws {
        let deepest = Folder(name: "Debug", children: [.plugin("a")], isCollapsed: true)
        let child = Folder(name: "Logs", children: [.folder(deepest)], isCollapsed: true)
        let root = Folder(name: "Tools", children: [.folder(child)], isCollapsed: true)
        var section = try Section(items: [.folder(root)])
        #expect(section.items == [.folder(root)])

        let original = section
        #expect(throws: Section.ValidationError.folderDepthExceeded) {
            try section.createFolder(named: "Too Deep", in: deepest.id)
        }
        #expect(section == original)

        var invalid = deepest
        invalid.children.append(.folder(.init(name: "Too Deep")))
        #expect(throws: Section.ValidationError.folderDepthExceeded) {
            try Section(items: [.folder(.init(name: "Tools", children: [
                .folder(.init(name: "Logs", children: [.folder(invalid)])),
            ]))])
        }
    }

    @Test("Blank names are rejected without changing the section", arguments: ["", " \n\t"])
    func rejectBlankNames(_ name: String) throws {
        let child = Folder(name: "Logs")
        let root = Folder(name: "Tools", children: [.folder(child)])
        var section = try Section(items: [.folder(root)])
        let original = section
        #expect(throws: Section.ValidationError.emptyFolderName) {
            try section.createFolder(named: name, in: root.id)
        }
        #expect(section == original)
        #expect(throws: Section.ValidationError.emptyFolderName) {
            try section.renameFolder(child.id, to: name)
        }
        #expect(section == original)
    }

    @Test("Equal folder names are allowed across parents and rejected among siblings")
    func validateSiblingNames() throws {
        let logs = Folder(name: " Logs \n")
        let traces = Folder(name: "Traces")
        let tools = Folder(name: "Tools", children: [.folder(logs), .folder(traces)], isCollapsed: true)
        let debug = Folder(name: "Debug")
        var section = try Section(items: [.folder(tools), .folder(debug)])
        let savedLogs = Folder(id: logs.id, name: "Logs")
        #expect(section.items == [
            .folder(.init(id: tools.id, name: "Tools", children: [.folder(savedLogs), .folder(traces)], isCollapsed: true)),
            .folder(debug),
        ])

        let debugLogs = try section.createFolder(named: "Logs", in: debug.id)
        #expect(section.items[1] == .folder(.init(id: debug.id, name: "Debug", children: [
            .folder(.init(id: debugLogs, name: "Logs")),
        ])))
        let original = section
        #expect(throws: Section.ValidationError.duplicateFolderName) {
            try section.createFolder(named: " Logs ", in: tools.id)
        }
        #expect(section == original)
        #expect(throws: Section.ValidationError.duplicateFolderName) {
            try section.renameFolder(traces.id, to: "Logs")
        }
        #expect(section == original)
        #expect(throws: Section.ValidationError.duplicateFolderName) {
            try Section(items: [.folder(.init(name: "Tools", children: [
                .folder(logs), .folder(.init(name: "Logs")),
            ]))])
        }
        #expect(throws: Section.ValidationError.emptyFolderName) {
            try Section(items: [.folder(.init(name: "Tools", children: [.folder(.init(name: " \n"))]))])
        }
    }

    @Test("Renaming a nested folder keeps its ID, children, position and collapse state")
    func renameFolder() throws {
        let archive = Folder(name: "Archive", children: [.plugin("b")], isCollapsed: true)
        let child = Folder(name: "Logs", children: [.plugin("unavailable"), .folder(archive)], isCollapsed: true)
        let root = Folder(name: "Tools", children: [.plugin("a"), .folder(child), .plugin("c")])
        var section = try Section(items: [.folder(root)])
        try section.renameFolder(child.id, to: " Logs ")
        #expect(section.items == [.folder(root)])
        try section.renameFolder(child.id, to: " Network ")
        var renamed = child
        renamed.name = "Network"
        #expect(section.items == [.folder(.init(id: root.id, name: "Tools", children: [
            .plugin("a"), .folder(renamed), .plugin("c"),
        ]))])
    }

    @Test("Deleting a root folder promotes its immediate children in order and keeps their subtrees")
    func deleteRootFolder() throws {
        let child = Folder(name: "Logs", children: [
            .plugin("unavailable-in-folder"), .folder(.init(name: "Archive", children: [.plugin("b")])),
        ])
        let root = Folder(name: "Tools", children: [.plugin("unavailable"), .folder(child), .plugin("c")])
        var section = try Section(items: [.plugin("a"), .folder(root), .plugin("d")])
        try section.deleteFolder(root.id)
        #expect(section.items == [.plugin("a"), .plugin("unavailable"), .folder(child), .plugin("c"), .plugin("d")])
    }

    @Test("Deleting a nested folder keeps its children in the same position")
    func deleteNestedFolder() throws {
        let deepest = Folder(name: "Archive", children: [.plugin("b")])
        let child = Folder(name: "Logs", children: [.folder(deepest), .plugin("unavailable")])
        let root = Folder(name: "Tools", children: [.plugin("a"), .folder(child), .plugin("c")])
        var section = try Section(items: [.folder(root)])
        try section.deleteFolder(child.id)
        #expect(section.items == [.folder(.init(id: root.id, name: "Tools", children: [
            .plugin("a"), .folder(deepest), .plugin("unavailable"), .plugin("c"),
        ]))])
    }

    @Test("Deleting an empty folder removes only that folder")
    func deleteEmptyFolder() throws {
        let empty = Folder(name: "Archive")
        let child = Folder(name: "Logs", children: [.plugin("a"), .folder(empty), .plugin("b")])
        let root = Folder(name: "Tools", children: [.folder(child)])
        var section = try Section(items: [.folder(root)])
        try section.deleteFolder(empty.id)
        #expect(section.items == [.folder(.init(id: root.id, name: "Tools", children: [
            .folder(.init(id: child.id, name: "Logs", children: [.plugin("a"), .plugin("b")])),
        ]))])
    }

    @Test("Promotion keeps existing and nonconflicting names and can reuse the deleted folder's name")
    func resolvePromotionNameCollisions() throws {
        let existing = Folder(name: "Logs", children: [.plugin("a")])
        let conflicting = Folder(name: "Logs", children: [.plugin("b")], isCollapsed: true)
        let suffixed = Folder(name: "Logs(1)", children: [.plugin("c")])
        let removed = Folder(name: "Logs(2)", children: [.folder(conflicting), .folder(suffixed)])
        let parent = Folder(name: "Tools", children: [.folder(existing), .folder(removed)])
        var section = try Section(items: [.folder(parent)])
        try section.deleteFolder(removed.id)
        #expect(section.items == [.folder(.init(id: parent.id, name: "Tools", children: [
            .folder(existing),
            .folder(.init(id: conflicting.id, name: "Logs(2)", children: conflicting.children, isCollapsed: true)),
            .folder(suffixed),
        ]))])
    }

    @Test("An unknown parent or folder leaves the section unchanged")
    func rejectUnknownFolder() throws {
        let root = Folder(name: "Tools", children: [.folder(.init(name: "Logs"))])
        var section = try Section(items: [.folder(root)])
        let original = section
        let missing = UUID()
        #expect(throws: Section.ValidationError.parentFolderNotFound) {
            try section.createFolder(named: "Debug", in: missing)
        }
        #expect(section == original)
        #expect(throws: Section.ValidationError.folderNotFound) { try section.renameFolder(missing, to: "Debug") }
        #expect(section == original)
        #expect(throws: Section.ValidationError.folderNotFound) { try section.deleteFolder(missing) }
        #expect(section == original)
    }

    @Test("A plugin ID can occupy only one location", arguments: [
        [Item.plugin("a"), .plugin("a")],
        [.plugin("a"), .folder(.init(name: "Tools", children: [.plugin("a")]))],
        [.folder(.init(name: "Tools", children: [.plugin("a"), .plugin("a")]))],
        [
            .folder(.init(name: "Tools", children: [.plugin("a")])),
            .folder(.init(name: "Logs", children: [.folder(.init(name: "Archive", children: [.plugin("a")]))])),
        ],
    ])
    func rejectDuplicatePluginIDs(_ items: [Item]) {
        #expect(throws: Section.ValidationError.duplicatePluginID) { try Section(items: items) }
    }

    @Test("Folder IDs must be unique across branches and depths")
    func rejectDuplicateFolderIDs() {
        let folder = Folder(name: "Logs")
        #expect(throws: Section.ValidationError.duplicateFolderID) {
            try Section(items: [
                .folder(.init(name: "Tools", children: [.folder(folder)])),
                .folder(.init(name: "Debug", children: [
                    .folder(.init(name: "Archive", children: [.folder(.init(id: folder.id, name: "More Logs"))])),
                ])),
            ])
        }
    }
}
