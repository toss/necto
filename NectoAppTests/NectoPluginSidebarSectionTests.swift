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
        let deepest = Folder(name: "Debug", children: [.plugin("a")])
        let child = Folder(name: "Logs", children: [.folder(deepest)])
        let root = Folder(name: "Tools", children: [.folder(child)])
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
        let tools = Folder(name: "Tools", children: [.folder(logs), .folder(traces)])
        let debug = Folder(name: "Debug")
        var section = try Section(items: [.folder(tools), .folder(debug)])
        let savedLogs = Folder(id: logs.id, name: "Logs")
        #expect(section.items == [
            .folder(.init(id: tools.id, name: "Tools", children: [.folder(savedLogs), .folder(traces)])),
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

    @Test("Renaming a nested folder keeps its ID, children and position")
    func renameFolder() throws {
        let child = Folder(name: "Logs", children: [
            .plugin("unavailable"), .folder(.init(name: "Archive", children: [.plugin("b")])),
        ])
        let root = Folder(name: "Tools", children: [.plugin("a"), .folder(child), .plugin("c")])
        var section = try Section(items: [.folder(root)])
        try section.renameFolder(child.id, to: " Logs ")
        #expect(section.items == [.folder(root)])
        try section.renameFolder(child.id, to: " Network ")
        #expect(section.items == [.folder(.init(id: root.id, name: "Tools", children: [
            .plugin("a"), .folder(.init(id: child.id, name: "Network", children: child.children)), .plugin("c"),
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
        let conflicting = Folder(name: "Logs", children: [.plugin("b")])
        let suffixed = Folder(name: "Logs(1)", children: [.plugin("c")])
        let removed = Folder(name: "Logs(2)", children: [.folder(conflicting), .folder(suffixed)])
        let parent = Folder(name: "Tools", children: [.folder(existing), .folder(removed)])
        var section = try Section(items: [.folder(parent)])
        try section.deleteFolder(removed.id)
        #expect(section.items == [.folder(.init(id: parent.id, name: "Tools", children: [
            .folder(existing),
            .folder(.init(id: conflicting.id, name: "Logs(2)", children: conflicting.children)),
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
