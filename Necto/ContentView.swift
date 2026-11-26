//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import SwiftUI

struct ContentView: View {
    let model: NectoAppModel
    @State private var window: NectoWindowState
    @State private var sidebarDrag = NectoPluginSidebarDrag()
    @State private var sidebarDropFeedback = NectoPluginSidebarDropTarget.Feedback()

    init(model: NectoAppModel) {
        self.model = model
        _window = State(initialValue: NectoWindowState(model: model))
    }

    private var ownsPresentation: Bool { model.presentationWindowID == window.id }

    @StateObject private var find = NectoFindSession()
    @State private var isSearchingPlugins = false
    @State private var folderToRename: FolderRename?
    @State private var createdFolderAnchor: NectoPluginSidebarRowID?
    @State private var searchScrollRequest: SearchScrollRequest?
    @State private var folderSaveFailed = false
    @AppStorage(NectoTextSize.key) private var textPoints = Double(NectoTextSize.base)
    @AppStorage(NectoFontPreference.uiKey) private var uiFontFamily = NectoFontPreference.defaultUI
    @AppStorage(NectoFontPreference.codeKey) private var codeFontFamily = NectoFontPreference.defaultCode
    @AppStorage(NectoLanguage.key) private var language = NectoLanguage.system.rawValue

    private var scale: CGFloat { NectoTextSize.scale(forPoints: CGFloat(textPoints)) }
    private var selectedLanguage: NectoLanguage { NectoLanguage(rawValue: language) ?? .system }

    /// The traffic lights float over whichever column is leftmost, so the row they land
    /// in has to leave them room. macOS draws them; everything else here is ours.
    private static let trafficLightsWidth: CGFloat = 78

    var body: some View {
        NectoSplitView(sidebar: sidebar, detail: detail)
            .background(NectoTheme.background)
            // The columns run to the top of the window, so the traffic lights sit inside
            // the sidebar rather than in a band of their own above both.
            .ignoresSafeArea(.container, edges: .top)
            .environment(\.locale, selectedLanguage.locale)
        .background(NectoWindowAttachment(state: window).frame(width: 0, height: 0))
        .task { await model.load(); claimBackgroundPanel() }
        .onChange(of: window.isMain) { _, isMain in
            if !isMain { clearSidebarDrag() }
            claimBackgroundPanel()
        }
        .onChange(of: window.selectedPluginID) { _, _ in claimBackgroundPanel() }
        .onChange(of: window.isShowingSettings) { _, _ in claimBackgroundPanel() }
        .onChange(of: model.enabledPlugins.map { "\($0.id)|\($0.contentIdentity)|\($0.principal?.sourceIdentity ?? "")" }) { _, _ in claimBackgroundPanel() }
        .onChange(of: model.prompt?.id) { _, _ in model.routePendingPrompt() }
        .onChange(of: model.shellAccess.pendingApproval?.id) { _, _ in model.routePendingPrompt() }
        .onReceive(NotificationCenter.default.publisher(for: .nectoShowSettings)) { _ in
            if window.isMain { window.isShowingSettings = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.updater.check(quietly: true) }
            Task {
                await model.load()
                await model.checkPluginUpdates()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nectoFindInPanel)) { _ in
            if window.isMain { find.open() }
        }
        .sheet(item: Binding(
            get: { ownsPresentation ? model.shellAccess.pendingApproval : nil },
            // A dismissal from an old sheet must not cancel the next request.
            set: { _ in }
        )) { pending in
            ShellApprovalSheet(
                pending: pending,
                pluginName: model.shellCallerName(for: pending.request.principal),
                pluginSource: model.shellCallerSource(for: pending.request.principal),
                scale: scale,
                deny: { model.shellAccess.denyPendingRequest(id: pending.id) },
                approve: { model.shellAccess.approvePendingRequest(id: pending.id) }
            )
            .interactiveDismissDisabled()
        }
        .sheet(item: Binding(get: { ownsPresentation ? model.prompt : nil }, set: { if $0 == nil, ownsPresentation { model.dismissPrompt() } })) { prompt in
            switch prompt {
            case let .approve(pending):
                PluginApprovalSheet(
                    staged: pending.staged,
                    scale: scale,
                    cancel: { model.cancelInstall() },
                    approve: { model.confirmInstall() }
                )
            case .address:
                PluginAddressSheet(
                    scale: scale,
                    isReading: model.isReadingRelease,
                    failure: model.installFailure,
                    cancel: { model.cancelAddingLink() },
                    add: { model.beginInstallFromLink($0) }
                )
            case let .choose(choice):
                PluginChoiceSheet(
                    choice: choice,
                    scale: scale,
                    installed: Set(model.plugins.filter { $0.source == .installed }.map(\.id)),
                    isBusy: model.isFetching,
                    fetching: model.fetchingAsset,
                    cancel: { model.cancelChoice() },
                    install: { model.install($0) }
                )
            }
        }
        .sheet(item: $folderToRename) { request in
            SidebarFolderRenameSheet(
                name: request.folder.name, scale: scale, cancel: { folderToRename = nil }
            ) { name in
                try model.pluginSidebar.edit(request.kind) { try $0.renameFolder(request.folder.id, to: name) }
                folderToRename = nil
            }
        }
        .alert(NectoL10n.text("Could not save the folder."), isPresented: $folderSaveFailed) {
            Button(NectoL10n.text("Done"), role: .cancel) {}
        }
    }

    private func claimBackgroundPanel() {
        guard window.isMain, !window.isShowingSettings, let plugin = window.selectedPlugin,
              plugin.runsInBackground else { return }
        model.backgroundPanels.present(plugin.id, in: window.id)
    }

    /// Rows are drawn rather than handed to `List`, because `List` brings AppKit's own
    /// selection: a tall pill in a colour and radius that are not the ones in
    /// docs/design.md. The shell and the plugin beside it have to agree.
    private var sidebar: some View {
        VStack(spacing: 0) {
            // This row owns the traffic-light clearance, so it must stay outside the
            // scrolling list. Otherwise the first device row can slide underneath the
            // window controls when the sidebar scrolls.
            TitleBar(leadingInset: Self.trafficLightsWidth, scale: scale) {}
                .background(NectoTheme.sidebar)
                .zIndex(1)
            sidebarList
            sidebarFoot
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NectoTheme.sidebar)
    }

    private enum SidebarAnchor: Hashable {
        case app(String)
    }

    private struct FolderRename: Identifiable {
        let kind: NectoPluginSidebarStore.Kind
        let folder: NectoPluginSidebarSection.Folder
        var id: UUID { folder.id }
    }

    private struct SearchScrollRequest: Equatable {
        let nonce = UUID()
        let anchor: NectoPluginSidebarRows.PluginAnchor
        let target: NectoTarget?
    }

    private var sidebarDragContext: NectoPluginSidebarDrag.Context {
        let target = window.selectedTarget
        let device = model.sidebarPluginIDs(in: .device, for: target)
        return .init(
            target: target,
            device: .init(
                layout: model.pluginSidebar[.device], activePluginIDs: device.active, disabledPluginIDs: device.disabled
            ),
            desktop: .init(
                layout: model.pluginSidebar[.desktop], activePluginIDs: model.sidebarPluginIDs(in: .desktop, for: target).active
            )
        )
    }

    /// A `List` for its selection, keyboard, accessibility and reordering.
    private var sidebarList: some View {
        let context = sidebarDragContext
        let activeDevice = window.activeDevicePlugins
        let disabledDevice = window.disabledDevicePlugins
        let showsDevice = model.pluginSidebar[.device].isVisible(
            hasAvailablePlugins: !activeDevice.isEmpty || !disabledDevice.isEmpty
        )
        return ScrollViewReader { proxy in
            List(selection: sidebarRowSelection) {
                if model.apps.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cable.connector.slash")
                        Text("No app connected")
                    }
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .plainRow()
                }

                ForEach(model.apps) { app in
                    AppHeader(
                        name: app.name,
                        bundleID: app.bundleID,
                        iconData: app.devices.first?.appIcon,
                        scale: scale
                    )
                    .plainRow()
                    .id(SidebarAnchor.app(app.id))

                    ForEach(app.devices) { device in
                        DeviceRow(
                            device: device,
                            isSelected: window.selectedAppID == device.id,
                            scale: scale
                        ) {
                            window.selectedAppID = device.id
                        }
                        .plainRow()
                    }
                }

                if showsDevice {
                    Section {
                        pluginGroup("Device Plugins", kind: .device, showsSearch: true)
                            .plainRow()
                        pluginRows(in: .device, active: activeDevice, disabled: disabledDevice, context: context)
                    }
                    .id(window.selectedTarget)
                }

                if model.pluginSidebar[.desktop].isVisible(hasAvailablePlugins: !model.enabledPlugins.isEmpty) {
                    Section {
                        pluginGroup("Desktop Plugins", kind: .desktop, showsSearch: !showsDevice)
                            .plainRow()
                        pluginRows(in: .desktop, active: model.enabledPlugins, context: context)
                    }
                }
            }
            .listStyle(.plain)
            .focusEffectDisabled()
            .listSectionSeparator(.hidden)
            .contentMargins(.all, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            // AppKit rejects a zero minimum; use the same height as the rows themselves.
            .environment(\.defaultMinListRowHeight, NectoTheme.rowHeight * scale)
            .clipped()
            .padding(.leading, 6)
            .onChange(of: context) { _, _ in clearSidebarDrag() }
            .onDisappear { clearSidebarDrag() }
            .onChange(of: Set(model.connectedApps.map(\.id))) { previous, current in
                guard !current.subtracting(previous).isEmpty, let first = model.apps.first else { return }
                // Wait for List to apply the inserted rows before resolving their positions.
                DispatchQueue.main.async {
                    proxy.scrollTo(SidebarAnchor.app(first.id), anchor: .top)
                }
            }
            .onChange(of: createdFolderAnchor) { _, anchor in
                guard let anchor else { return }
                DispatchQueue.main.async { proxy.scrollTo(anchor) }
            }
            .onChange(of: searchScrollRequest) { _, request in
                guard let request else { return }
                DispatchQueue.main.async {
                    guard request == searchScrollRequest, request.target == window.selectedTarget,
                          request.anchor.id == sidebarSelection.wrappedValue else { return }
                    proxy.scrollTo(request.anchor)
                }
            }
        }
    }

    @ViewBuilder
    private func pluginGroup(_ title: String, kind: NectoPluginSidebarStore.Kind, showsSearch: Bool) -> some View {
        let target = window.selectedTarget
        let header = HStack(spacing: 0) {
            SidebarGroup(title: NectoL10n.text(title), scale: scale)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { createFolder(in: kind) } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(SidebarIconButtonStyle(scale: scale))
                .help(NectoL10n.text("New Folder"))
                .accessibilityLabel(NectoL10n.text("New Folder"))
                .accessibilityIdentifier("sidebar.plugin.folder.create.\(kind.rawValue)")

                if showsSearch {
                    SidebarPluginSearch(
                        devicePlugins: window.activeDevicePlugins + window.disabledDevicePlugins,
                        desktopPlugins: model.enabledPlugins,
                        disabledPluginIDs: Set(window.disabledDevicePlugins.map(\.id)),
                        scale: scale, selection: sidebarSelection.wrappedValue,
                        selectResult: { selectSearchResult($0, in: $1, target: target) },
                        isSearching: $isSearchingPlugins
                    )
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 8)
        }
        if showsSearch {
            header.accessibilityAction(named: Text(NectoL10n.text("Search plugins"))) {
                isSearchingPlugins = true
            }
        } else {
            header
        }
    }

    private func pluginRows(
        in kind: NectoPluginSidebarStore.Kind,
        active: [NectoInstalledPlugin],
        disabled: [NectoInstalledPlugin] = [],
        context: NectoPluginSidebarDrag.Context
    ) -> some View {
        let section = context[kind]
        let visibleRows = section.layout.visibleRows(
            activePluginIDs: section.activePluginIDs, disabledPluginIDs: section.disabledPluginIDs
        )
        func allowsDrop(to destination: NectoPluginSidebarSection.MoveDestination) -> Bool {
            context == sidebarDragContext && sidebarDrag.allowsDrop(to: destination, in: kind, context: context)
        }
        return NectoPluginSidebarRows(
            kind: kind,
            siblingsByParent: section.layout.visibleSiblings(
                activePluginIDs: section.activePluginIDs, disabledPluginIDs: section.disabledPluginIDs
            ),
            visibleRows: visibleRows,
            plugins: Dictionary((active + disabled).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            scale: scale,
            selectedPluginID: window.isShowingSettings ? nil : window.selectedPluginID,
            actions: .init(
                expandFolder: { setFolderExpanded($1, folderID: $0, in: kind) },
                createFolder: { createFolder(in: kind, parentID: $0) },
                renameFolder: { folderToRename = FolderRename(kind: kind, folder: $0) },
                deleteFolder: { id in editSidebar(kind) { try $0.deleteFolder(id) } },
                setEnabled: { plugin, enabled in
                    guard context.target == window.selectedTarget else { return }
                    model.setPlugin(plugin, enabled: enabled, deviceTarget: context.target)
                },
                reorder: { source, anchor, position, parentID in
                    let location = NectoPluginSidebarState.ItemLocation(kind: kind, id: source, parentID: parentID)
                    guard context == sidebarDragContext, sidebarDrag.source(in: context) == location else { return }
                    _ = sidebarDrag.takeNativeSource(in: context)
                    sidebarDropFeedback.clear()
                    model.reorderSidebar(
                        location,
                        relativeTo: .init(kind: kind, id: anchor, parentID: parentID),
                        position: position,
                        target: context.target
                    )
                },
                dragProvider: { row in
                    guard context == sidebarDragContext else { return nil }
                    let source = NectoPluginSidebarState.ItemLocation(kind: kind, id: row.id, parentID: row.parentID)
                    if sidebarDrag.source(in: context) != source { sidebarDropFeedback.highlight = nil }
                    if sidebarDropFeedback.nativeReorderSource != source {
                        sidebarDropFeedback.nativeReorderSource = source
                    }
                    return sidebarDrag.provider(for: source, in: context)
                },
                dropFeedback: sidebarDropFeedback,
                acceptsDrop: { context == sidebarDragContext && sidebarDrag.acceptsDrop(in: context) },
                allowsDrop: allowsDrop,
                receiveDrop: { destination, providers in
                    guard allowsDrop(to: destination) else { return false }
                    sidebarDropFeedback.clear()
                    return sidebarDrag.receive(providers, context: context, currentContext: { sidebarDragContext }) { source in
                        model.moveSidebar(source, to: destination, in: kind, target: context.target)
                    }
                }
            )
        )
    }

    private func clearSidebarDrag() {
        sidebarDrag.clear()
        sidebarDropFeedback.clear()
    }

    private func setFolderExpanded(_ expanded: Bool, folderID: UUID, in kind: NectoPluginSidebarStore.Kind) {
        guard let folder = model.pluginSidebar[kind].folder(withID: folderID), folder.isCollapsed == expanded else {
            return
        }
        editSidebar(kind) { try $0.toggleFolder(folderID) }
    }

    private func selectSearchResult(_ id: String, in kind: NectoPluginSidebarStore.Kind, target: NectoTarget?) {
        guard target == window.selectedTarget else { return }
        let available = model.sidebarPluginIDs(in: kind, for: target)
        guard available.active.contains(id) || available.disabled.contains(id) else { return }
        if let revealed = model.pluginSidebar[kind].revealingPlugin(id) {
            guard editSidebar(kind, { $0 = revealed }) != nil else { return }
        }
        sidebarSelection.wrappedValue = id
        searchScrollRequest = SearchScrollRequest(anchor: .init(kind: kind, id: id), target: target)
    }

    private func createFolder(in kind: NectoPluginSidebarStore.Kind, parentID: UUID? = nil) {
        let id = editSidebar(kind) {
            try $0.createFolder(defaultName: NectoL10n.text("New Folder"), in: parentID)
        }
        if let id { createdFolderAnchor = .folder(kind, id) }
    }

    @discardableResult
    private func editSidebar<Result>(
        _ kind: NectoPluginSidebarStore.Kind,
        _ edit: (inout NectoPluginSidebarSection) throws -> Result
    ) -> Result? {
        do {
            return try model.pluginSidebar.edit(kind, edit)
        } catch {
            folderSaveFailed = true
            return nil
        }
    }

    /// Below the scroll view rather than inside it: a `Spacer` in a scroll view has no
    /// room to push into, so Settings ended up under the plugin list instead of at the
    /// foot of the sidebar. Outside it also stays put while a long list scrolls.
    private var sidebarFoot: some View {
        VStack(spacing: 0) {
            Rectangle().fill(NectoTheme.border).frame(height: 1)

            SidebarItem(
                title: NectoL10n.text("Settings"),
                systemImage: "slider.horizontal.3",
                // The count rather than a bare dot: one plugin that would not load and
                // eleven refused calls are different situations.
                trailing: model.unreadIssueCount > 0 ? String(model.unreadIssueCount) : "",
                trailingIsIssue: model.unreadIssueCount > 0,
                isSelected: window.isShowingSettings,
                scale: scale,
                hasUpdate: model.updater.hasUpdate || !model.pluginUpdates.isEmpty
            ) {
                window.isShowingSettings = true
            }
            .padding(.vertical, 8)
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            TitleBar(leadingInset: 12, scale: scale) {
                heading
            }
            .background(NectoTheme.background)
            .zIndex(1)

            ZStack {
                ForEach(model.enabledPlugins.filter(\.runsInBackground)) { plugin in
                    let visible = !window.isShowingSettings && window.disabledSelection == nil && window.selectedPlugin?.id == plugin.id
                    NectoBackgroundPluginView(
                        page: model.backgroundPanels.page(for: plugin.id),
                        ownsPage: model.backgroundPanels.owner(of: plugin.id) == window.id,
                        isVisible: visible,
                        textScale: scale,
                        uiFontFamily: uiFontFamily,
                        codeFontFamily: codeFontFamily,
                        locale: NectoL10n.languageCode,
                        find: find
                    )
                    .id("\(plugin.id)|\(plugin.principal?.sourceIdentity ?? "")|\(plugin.contentIdentity)")
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                content
            }
        }
        .background(NectoTheme.background)
    }

    @ViewBuilder
    private var heading: some View {
        if window.isShowingSettings {
            ScreenHeading(
                systemImage: "slider.horizontal.3",
                title: NectoL10n.text("Settings"),
                scale: scale
            )
        } else if let plugin = window.disabledSelection {
            ScreenHeading(systemImage: plugin.manifest.icon.systemName, title: plugin.manifest.name, scale: scale)
        } else if let plugin = window.selectedPlugin {
            ScreenHeading(
                systemImage: plugin.manifest.icon.systemName,
                title: plugin.manifest.name,
                help: plugin.manifest.description,
                scale: scale
            )
        }
    }

    private var sidebarRowSelection: Binding<NectoPluginSidebarRowID?> {
        Binding(
            get: { sidebarSelection.wrappedValue.map(NectoPluginSidebarRowID.plugin) },
            set: { row in
                switch row {
                case .plugin(let id):
                    sidebarSelection.wrappedValue = id
                case .folder(let kind, let id):
                    guard let folder = model.pluginSidebar[kind].folder(withID: id) else { return }
                    setFolderExpanded(folder.isCollapsed, folderID: id, in: kind)
                case nil:
                    break
                }
            }
        )
    }

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { window.isShowingSettings ? nil : window.selectedPluginID },
            set: { id in
                guard let id else { return }
                window.selectedPluginID = id
                window.isShowingSettings = false
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if window.isShowingSettings {
            SettingsScreen(model: model)
        } else if let plugin = window.disabledSelection {
            VStack(spacing: 4) {
                Text(NectoL10n.format("%@ is disabled", plugin.manifest.name))
                    .font(.necto(.body, scale: scale))
                    .foregroundStyle(NectoTheme.textSecondary)
                Text("The app still carries it. Nothing is shown on this Mac.")
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                Button(NectoL10n.text("Enable")) { model.setPlugin(plugin, enabled: true) }
                    .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plugin = window.selectedPlugin {
            if plugin.runsInBackground {
                if model.backgroundPanels.owner(of: plugin.id) == window.id {
                    Color.clear.allowsHitTesting(false)
                } else {
                    NectoEmpty(title: NectoL10n.text("This plugin is displayed in another window."),
                               detail: NectoL10n.text("Activate this window to bring it here."), scale: scale)
                }
            } else {
                NectoPluginWebView(
                    plugin: plugin,
                    registry: model.registry,
                    target: window.selectedTarget,
                    textScale: scale,
                    uiFontFamily: uiFontFamily,
                    codeFontFamily: codeFontFamily,
                    locale: NectoL10n.languageCode,
                    find: find
                )
                // A different installation or approved snapshot needs a fresh scheme handler.
                .id("\(plugin.id)|\(plugin.principal?.sourceIdentity ?? "")|\(plugin.contentIdentity)|\(window.selectedAppID ?? "")")
                // A WKWebView has no intrinsic size, so in a stack it can be handed none.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            NectoEmpty(
                title: NectoL10n.text("No plugins yet"),
                detail: NectoL10n.text("Connect an app and its plugins appear here on their own."),
                scale: scale
            )
        }
    }
}
