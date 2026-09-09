//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoModel
import Observation
import SwiftUI

/// Selection belongs to a window; services and plugin execution belong to the app.
@MainActor
@Observable
final class NectoWindowState {
    let id = UUID()
    let model: NectoAppModel
    @ObservationIgnored weak var window: NSWindow?
    var isMain = false
    var isShowingSettings = false
    private var pluginID: String?
    private var appID: String?

    init(model: NectoAppModel) { self.model = model }

    var selectedAppID: String? {
        get { model.connectedApps.first { $0.id == appID }?.id ?? model.connectedApps.first?.id }
        set { appID = newValue }
    }

    var selectedTarget: NectoTarget? { model.connectedApps.first { $0.id == selectedAppID }?.target }
    var activeDevicePlugins: [NectoInstalledPlugin] { model.activeDevicePlugins(for: selectedTarget) }
    var disabledDevicePlugins: [NectoInstalledPlugin] { model.disabledDevicePlugins(for: selectedTarget) }

    var selectedPluginID: String? {
        get {
            let available = model.enabledPlugins + activeDevicePlugins + disabledDevicePlugins
            return available.first { $0.id == pluginID }?.id
                ?? model.enabledPlugins.first?.id ?? activeDevicePlugins.first?.id
        }
        set { pluginID = newValue }
    }

    var selectedPlugin: NectoInstalledPlugin? {
        (model.enabledPlugins + activeDevicePlugins).first { $0.id == selectedPluginID }
    }

    var disabledSelection: NectoInstalledPlugin? {
        disabledDevicePlugins.first { $0.id == selectedPluginID }
    }
}

/// Associates the actual SwiftUI window with its selection and presentation state.
struct NectoWindowAttachment: NSViewRepresentable {
    let state: NectoWindowState
    func makeNSView(context: Context) -> Attachment { Attachment(state: state) }
    func updateNSView(_ view: Attachment, context: Context) {}
    static func dismantleNSView(_ view: Attachment, coordinator: ()) { view.detach() }

    final class Attachment: NSView {
        let state: NectoWindowState
        private var observers: [NSObjectProtocol] = []

        init(state: NectoWindowState) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            state.window = window
            state.isMain = window.isMainWindow
            state.model.registerWindow(state)
            for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.state.isMain = self?.window?.isMainWindow == true }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            })
            state.model.routePendingPrompt()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard state.window != nil else { return }
            state.window = nil
            state.isMain = false
            state.model.unregisterWindow(state)
        }
    }
}
