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

    struct Actions {
        let expandFolder: (UUID, Bool) -> Void
        let createFolder: (UUID) -> Void
        let renameFolder: (Section.Folder) -> Void
        let deleteFolder: (UUID) -> Void
        let setEnabled: (NectoInstalledPlugin, Bool) -> Void
        let reorder: (Section.Item.ID, Section.Item.ID, Section.InsertionPosition, UUID?) -> Void
    }

    let kind: NectoPluginSidebarStore.Kind
    let siblingsByParent: [UUID?: [Section.Row]]
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
            switch row.item {
            case .plugin(let id):
                if let plugin = plugins[id] {
                    pluginRow(plugin, isDimmed: row.isDimmed)
                        .moveDisabled(!row.canReorder)
                        .tag(entry.id)
                }
            case .folder(let folder):
                DisclosureGroup(isExpanded: expansion(for: folder)) {
                    NectoPluginSidebarRows(
                        kind: kind,
                        siblingsByParent: siblingsByParent,
                        plugins: plugins,
                        scale: scale,
                        selectedPluginID: selectedPluginID,
                        actions: actions,
                        parentID: folder.id
                    )
                } label: {
                    folderLabel(folder, row: row)
                        .tag(entry.id)
                        .listRowSeparator(.hidden)
                }
                .moveDisabled(!row.canReorder)
                .listRowSeparator(.hidden)
            }
        }
        .onMove { sources, destination in
            guard let insertion = Section.insertion(from: sources, to: destination, in: siblings) else { return }
            actions.reorder(insertion.source.id, insertion.anchor.id, insertion.position, parentID)
        }
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
            isDimmed: isDimmed
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
        Label(folder.name, systemImage: "folder")
            .font(.necto(.label, scale: scale))
            .foregroundStyle(row.isDimmed ? NectoTheme.textTertiary : NectoTheme.textSecondary)
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
