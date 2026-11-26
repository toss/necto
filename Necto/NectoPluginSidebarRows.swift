//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

enum NectoPluginSidebarRowID: Hashable {
    case plugin(String)
    case folder(NectoPluginSidebarStore.Kind, UUID)
}

struct NectoPluginSidebarRows: View {
    typealias Section = NectoPluginSidebarSection
    private static let iconSpacing: CGFloat = 4

    struct Actions {
        let expandFolder: (UUID, Bool) -> Void
        let createFolder: (UUID) -> Void
        let renameFolder: (Section.Folder) -> Void
        let deleteFolder: (UUID) -> Void
        let setEnabled: (NectoInstalledPlugin, Bool) -> Void
        let reorder: (Section.Item.ID, Section.Item.ID, Section.InsertionPosition, UUID?) -> Void
        let dragProvider: (Section.Row) -> NSItemProvider?
        let dropFeedback: NectoPluginSidebarDropTarget.Feedback
        let acceptsDrop: () -> Bool
        let allowsDrop: (Section.MoveDestination) -> Bool
        let receiveDrop: (Section.MoveDestination, [NSItemProvider]) -> Bool
    }

    let kind: NectoPluginSidebarStore.Kind
    let siblingsByParent: [UUID?: [Section.Row]]
    let visibleRows: [Section.Row]
    let plugins: [String: NectoInstalledPlugin]
    let scale: CGFloat
    let selectedPluginID: String?
    let actions: Actions
    var parentID: UUID? = nil

    private struct IdentifiedRow: Identifiable {
        let row: Section.Row
        let kind: NectoPluginSidebarStore.Kind

        var id: NectoPluginSidebarRowID {
            switch row.id {
            case .plugin(let id): .plugin(id)
            case .folder(let id): .folder(kind, id)
            }
        }
    }

    var body: some View {
        let siblings = siblingsByParent[parentID, default: []]
        ForEach(siblings.map { IdentifiedRow(row: $0, kind: kind) }) { entry in
            let row = entry.row
            let provider = itemProvider(for: row)
            switch row.item {
            case .plugin(let id):
                if let plugin = plugins[id] {
                    pluginRow(plugin, isDimmed: row.isDimmed)
                        .overlay { dropRegions(for: row, in: siblings) }
                        .moveDisabled(provider == nil)
                        .tag(entry.id)
                        .itemProvider(provider)
                }
            case .folder(let folder):
                DisclosureGroup(isExpanded: expansion(for: folder)) {
                    NectoPluginSidebarRows(
                        kind: kind,
                        siblingsByParent: siblingsByParent,
                        visibleRows: visibleRows,
                        plugins: plugins,
                        scale: scale,
                        selectedPluginID: selectedPluginID,
                        actions: actions,
                        parentID: folder.id
                    )
                } label: {
                    folderLabel(folder, row: row)
                        .overlay { dropRegions(for: row, in: siblings, center: .into(parentID: folder.id)) }
                        .tag(entry.id)
                        .listRowSeparator(.hidden)
                        .moveDisabled(provider == nil)
                        .itemProvider(provider)
                }
                .moveDisabled(provider == nil)
                .listRowSeparator(.hidden)
            }
        }
        .onMove { sources, destination in
            guard let insertion = Section.insertion(from: sources, to: destination, in: siblings) else { return }
            actions.reorder(insertion.source.id, insertion.anchor.id, insertion.position, parentID)
        }
    }

    private func itemProvider(for row: Section.Row) -> (() -> NSItemProvider?)? {
        guard row.canChangeParent(in: kind) else { return nil }
        return { actions.dragProvider(row) }
    }

    private func dropRegions(
        for row: Section.Row, in siblings: [Section.Row], center: Section.MoveDestination? = nil
    ) -> some View {
        let lastDescendantID = center == nil ? nil : visibleRows.first { $0.id == row.id }?.lastVisibleDescendantID
        let afterRow = lastDescendantID.flatMap { id in visibleRows.first { $0.id == id } } ?? row
        return NectoPluginSidebarDropTarget(
            kind: kind, rowID: row.id, parentID: row.parentID,
            before: Section.dropDestination(beside: row.id, position: .before, in: siblings),
            center: center,
            after: Section.dropDestination(beside: row.id, position: .after, in: siblings),
            afterRowID: afterRow.id,
            afterLeadingExtension: CGFloat(afterRow.depth - row.depth) * NectoTheme.sidebarIndentation,
            feedback: actions.dropFeedback, acceptsDrop: actions.acceptsDrop,
            allowsDrop: actions.allowsDrop, receive: actions.receiveDrop
        )
        .frame(minHeight: NectoTheme.rowHeight * scale)
    }

    private func expansion(for folder: Section.Folder) -> Binding<Bool> {
        Binding(
            get: { !folder.isCollapsed },
            set: { actions.expandFolder(folder.id, $0) }
        )
    }

    private func pluginRow(_ plugin: NectoInstalledPlugin, isDimmed: Bool) -> some View {
        let isSelected = selectedPluginID == plugin.id
        return SidebarItem(
            title: plugin.manifest.name,
            systemImage: plugin.manifest.icon.systemName,
            trailing: isDimmed ? NectoL10n.text("off") : plugin.manifest.version,
            isSelected: isSelected,
            scale: scale,
            isDimmed: isDimmed,
            leadingInset: 0,
            iconSpacing: Self.iconSpacing
        )
        .contextMenu {
            if kind == .device {
                Button(NectoL10n.text(isDimmed ? "Enable" : "Disable")) {
                    actions.setEnabled(plugin, isDimmed)
                }
            }
        }
        .plainRow(isSelected: isSelected)
    }

    private func folderLabel(_ folder: Section.Folder, row: Section.Row) -> some View {
        let label = HStack(spacing: Self.iconSpacing) {
            Image(systemName: "folder")
                .frame(width: SidebarItem.iconWidth)
                .accessibilityHidden(true)
            Text(folder.name)
        }
        return label
            .font(.necto(.label, scale: scale))
            .foregroundStyle(row.isDimmed ? NectoTheme.textTertiary : NectoTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("sidebar.plugin.folder.\(kind.rawValue).\(folder.id.uuidString)")
            .contextMenu {
                if row.depth < Section.maximumFolderDepth {
                    Button(NectoL10n.text("New Folder")) { actions.createFolder(folder.id) }
                }
                Button(NectoL10n.text("Rename Folder")) { actions.renameFolder(folder) }
                Button(NectoL10n.text("Delete Folder"), role: .destructive) { actions.deleteFolder(folder.id) }
            }
    }
}
