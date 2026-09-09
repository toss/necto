//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import SwiftUI

struct ContentView: View {
    let model: NectoAppModel
    @State private var window: NectoWindowState

    init(model: NectoAppModel) {
        self.model = model
        _window = State(initialValue: NectoWindowState(model: model))
    }

    private var ownsPresentation: Bool { model.presentationWindowID == window.id }

    @StateObject private var find = NectoFindSession()
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
        .onChange(of: window.isMain) { _, _ in claimBackgroundPanel() }
        .onChange(of: window.selectedPluginID) { _, _ in claimBackgroundPanel() }
        .onChange(of: window.isShowingSettings) { _, _ in claimBackgroundPanel() }
        .onChange(of: model.enabledPlugins.map { "\($0.id)|\($0.contentIdentity)|\($0.principal?.sourceIdentity ?? "")" }) { _, _ in claimBackgroundPanel() }
        .onChange(of: model.prompt?.id) { _, _ in model.routePendingPrompt() }
        .onChange(of: model.shellAccess.pendingApproval?.id) { _, _ in model.routePendingPrompt() }
        .onReceive(NotificationCenter.default.publisher(for: .nectoShowSettings)) { _ in
            if window.isMain { window.isShowingSettings = true }
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

    /// A `List` for its selection, its keyboard, its accessibility and its reordering.
    ///
    /// Hand-drawing these rows cost the sidebar all four — all to avoid one selection
    /// highlight. The platform does the list; the highlight is suppressed in
    /// `ListChromeOff` instead.
    private var sidebarList: some View {
        List(selection: sidebarSelection) {
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

            if !window.activeDevicePlugins.isEmpty || !window.disabledDevicePlugins.isEmpty {
                Section {
                    ForEach(window.activeDevicePlugins) { plugin in
                        SidebarItem(
                            title: plugin.manifest.name,
                            systemImage: plugin.manifest.icon.systemName,
                            trailing: plugin.manifest.version,
                            isSelected: !window.isShowingSettings && window.selectedPluginID == plugin.id,
                            scale: scale
                        )
                        .contextMenu {
                            Button(NectoL10n.text("Disable")) { model.setPlugin(plugin.id, enabled: false) }
                        }
                        .plainRow(isSelected: window.selectedPluginID == plugin.id)
                        .tag(plugin.id)
                    }
                    .onMove { from, to in
                        model.moveDevicePlugins(from: from, to: to, target: window.selectedTarget)
                    }

                    // The disabled sink to the bottom, in gray. Clicking one is not a
                    // dead end: its pane says what happened and offers the way back.
                    ForEach(window.disabledDevicePlugins) { plugin in
                        SidebarItem(
                            title: plugin.manifest.name,
                            systemImage: plugin.manifest.icon.systemName,
                            trailing: NectoL10n.text("off"),
                            isSelected: !window.isShowingSettings && window.selectedPluginID == plugin.id,
                            scale: scale,
                            isDimmed: true
                        )
                        .contextMenu {
                            Button(NectoL10n.text("Enable")) { model.setPlugin(plugin.id, enabled: true) }
                        }
                        .plainRow(isSelected: window.selectedPluginID == plugin.id)
                        .tag(plugin.id)
                    }
                } header: {
                    // The category words, straight from the architecture: what the
                    // selected device's app carries, then what this Mac installed.
                    SidebarGroup(title: NectoL10n.text("Device Plugins"), scale: scale)
                        .plainRow()
                        .listRowBackground(NectoTheme.sidebar)
                }
            }

            if !model.enabledPlugins.isEmpty {
                Section {
                    // `editActions: .move` rather than a drag of our own: `ForEach`
                    // writes the rearranged list straight back through the binding, and
                    // the drag, its animation and the keyboard all stay the platform's.
                    ForEach(model.enabledPlugins) { plugin in
                        SidebarItem(
                            title: plugin.manifest.name,
                            systemImage: plugin.manifest.icon.systemName,
                            trailing: plugin.manifest.version,
                            isSelected: !window.isShowingSettings && window.selectedPluginID == plugin.id,
                            scale: scale
                        )
                        .plainRow(isSelected: window.selectedPluginID == plugin.id)
                        .tag(plugin.id)
                    }
                    .onMove { from, to in
                        model.movePlugins(from: from, to: to)
                    }
                } header: {
                    SidebarGroup(title: NectoL10n.text("Desktop Plugins"), scale: scale)
                        .plainRow()
                        // A section header is sticky and gets a material behind it
                        // unless it is told otherwise.
                        .listRowBackground(NectoTheme.sidebar)
                }
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.visible, axes: .vertical)
        .focusEffectDisabled()
        .listSectionSeparator(.hidden)
        .contentMargins(.all, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        // AppKit rejects a zero minimum; use the same height as the rows themselves.
        .environment(\.defaultMinListRowHeight, NectoTheme.rowHeight * scale)
        .clipped()
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
                trailing: updaterIsQuiet && model.unreadIssueCount > 0 ? String(model.unreadIssueCount) : "",
                trailingIsIssue: model.unreadIssueCount > 0,
                isSelected: window.isShowingSettings,
                scale: scale
            ) {
                window.isShowingSettings = true
            }
            .overlay(alignment: .trailing) {
                sidebarUpdateControl.padding(.trailing, 16)
            }
            .padding(.vertical, 8)
        }
    }

    private var updaterIsQuiet: Bool {
        switch model.updater.phase {
        case .available, .working: false
        default: true
        }
    }

    /// The one place an update announces itself: a button beside Settings, and the
    /// step it is on while it runs. Everything quieter stays in the About row.
    @ViewBuilder
    private var sidebarUpdateControl: some View {
        switch model.updater.phase {
        case .available:
            Button(NectoL10n.text("Update")) { Task { await model.updater.update() } }
                .buttonStyle(NectoButtonStyle(scale: scale, primary: true))
        case let .working(step):
            Text(step)
                .font(.necto(.caption, scale: scale))
                .foregroundStyle(NectoTheme.textTertiary)
        default:
            EmptyView()
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
                Button(NectoL10n.text("Enable")) { model.setPlugin(plugin.id, enabled: true) }
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
