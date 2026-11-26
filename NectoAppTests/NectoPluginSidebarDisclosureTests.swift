//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Testing

@Suite("Plugin sidebar disclosure groups")
struct NectoPluginSidebarDisclosureTests {
    typealias Section = NectoPluginSidebarSection

    @Test("Disclosure groups keep visible children and disabled rows under their saved parents")
    func visibleSiblings() throws {
        let closed = Section.Folder(name: "Closed", children: [.plugin("closed")], isCollapsed: true)
        let unavailable = Section.Folder(name: "Unavailable", children: [.plugin("missing")])
        let tools = Section.Folder(name: "Tools", children: [
            .folder(unavailable), .plugin("hidden"), .plugin("off"), .plugin("visible"),
        ])
        let section = try Section(items: [.folder(closed), .folder(tools), .plugin("root-off")])
        let siblings = section.visibleSiblings(
            activePluginIDs: ["closed", "visible"], disabledPluginIDs: ["off", "root-off"]
        )

        #expect(siblings[nil]?.map(\.id) == [.folder(closed.id), .folder(tools.id), .plugin("root-off")])
        #expect(siblings[nil]?.last?.isDimmed == true)
        #expect(siblings[closed.id] == nil)
        let children = try #require(siblings[tools.id])
        #expect(children.map(\.id) == [.folder(unavailable.id), .plugin("off"), .plugin("visible")])
        #expect(children.filter(\.isDimmed).map(\.id) == [.plugin("off")])
        #expect(section.folder(withID: unavailable.id) == unavailable)
    }

    @Test("A root reorder after an expanded folder anchors to the folder rather than its last child")
    func insertAfterExpandedSibling() throws {
        let folder = Section.Folder(name: "Tools", children: [.plugin("child")])
        var section = try Section(items: [.plugin("move"), .folder(folder), .plugin("hidden"), .plugin("end")])
        let siblings = try #require(section.visibleSiblings(
            activePluginIDs: ["move", "child", "end"], disabledPluginIDs: []
        )[nil])

        let insertion = try #require(Section.insertion(from: [0], to: 2, in: siblings))
        #expect(insertion.anchor.id == .folder(folder.id))
        #expect(try section.reorder(
            insertion.source.id,
            relativeTo: insertion.anchor.id,
            position: insertion.position,
            in: insertion.source.parentID
        ))
        #expect(section.items == [.folder(folder), .plugin("move"), .plugin("hidden"), .plugin("end")])
    }

    @Test("A nested reorder uses its sibling indices and preserves hidden child order")
    func insertAmongNestedSiblings() throws {
        let folder = Section.Folder(name: "Tools", children: [.plugin("a"), .plugin("hidden"), .plugin("b")])
        var section = try Section(items: [.plugin("other"), .folder(folder)])
        let siblings = try #require(section.visibleSiblings(
            activePluginIDs: ["other", "a", "b"], disabledPluginIDs: []
        )[folder.id])

        #expect(Section.insertion(from: [0], to: 3, in: siblings) == nil)
        let insertion = try #require(Section.insertion(from: [0], to: 2, in: siblings))
        #expect(try section.reorder(
            insertion.source.id,
            relativeTo: insertion.anchor.id,
            position: insertion.position,
            in: insertion.source.parentID
        ))
        #expect(section.pluginIDs == ["other", "hidden", "b", "a"])
    }
}
