//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoMacService
import Observation
import SwiftUI

/// One page per approved background plugin, independent of the number of windows.
@MainActor
@Observable
final class NectoBackgroundPanels {
    private struct Entry {
        let identity: String
        let page: NectoPluginPage
    }
    private var entries: [String: Entry] = [:]
    private var owners: [String: UUID] = [:]

    func synchronize(plugins: [NectoInstalledPlugin], registry: NectoPluginRegistry) {
        let identities = Dictionary(uniqueKeysWithValues: plugins.map {
            ($0.id, "\($0.principal?.sourceIdentity ?? "")|\($0.contentIdentity)")
        })
        for id in Array(entries.keys) where entries[id]?.identity != identities[id] {
            entries.removeValue(forKey: id)?.page.invalidate()
            owners.removeValue(forKey: id)
        }
        for plugin in plugins where entries[plugin.id] == nil {
            let page = NectoPluginPage(plugin: plugin, registry: registry, target: nil, locale: NectoL10n.languageCode)
            page.setVisible(false, find: nil, scale: 1)
            entries[plugin.id] = Entry(identity: identities[plugin.id]!, page: page)
        }
    }

    func page(for id: String) -> NectoPluginPage? { entries[id]?.page }
    func owner(of id: String) -> UUID? { owners[id] }
    func present(_ id: String, in windowID: UUID) {
        guard entries[id] != nil else { return }
        owners[id] = windowID
    }
    func release(windowID: UUID) { owners = owners.filter { $0.value != windowID } }
}

/// A window borrows the retained page. Moving it never reloads the plugin document.
struct NectoBackgroundPluginView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let page: NectoPluginPage?
    let ownsPage: Bool
    let isVisible: Bool
    let textScale: CGFloat
    let uiFontFamily: String
    let codeFontFamily: String
    let locale: String
    let find: NectoFindSession

    final class Coordinator { var page: NectoPluginPage? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.page = page
        guard let page else { return }
        guard ownsPage else {
            if page.webView.superview === container {
                page.setVisible(false, find: nil, scale: textScale)
                page.webView.removeFromSuperview()
            }
            return
        }
        if page.webView.superview !== container {
            page.setVisible(false, find: nil, scale: textScale)
            page.webView.removeFromSuperview()
            page.webView.frame = container.bounds
            page.webView.autoresizingMask = [.width, .height]
            container.addSubview(page.webView)
        }
        page.configure(target: nil, textScale: textScale, uiFontFamily: uiFontFamily,
                       codeFontFamily: codeFontFamily, locale: locale, isDark: colorScheme == .dark)
        page.setVisible(isVisible, find: find, scale: textScale)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        guard let page = coordinator.page, page.webView.superview === container else { return }
        page.setVisible(false, find: nil, scale: 1)
        page.webView.removeFromSuperview()
    }
}
