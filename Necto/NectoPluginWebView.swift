//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoMacService
import Foundation
import SwiftUI
import WebKit

/// Loads a plugin's web assets and forwards its `NectoBridge` requests to the registry.
struct NectoPluginWebView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    let plugin: NectoInstalledPlugin
    let registry: NectoPluginRegistry
    let target: NectoTarget?
    /// Passed through so a plugin's text scales with the app's preference.
    var textScale: CGFloat = 1
    var uiFontFamily = NectoFontPreference.defaultUI
    var codeFontFamily = NectoFontPreference.defaultCode
    var locale = "en"
    /// The host's find bar searches whatever view is showing, so the view says which.
    var find: NectoFindSession?
    var isVisible = true

    func makeCoordinator() -> NectoPluginPage {
        NectoPluginPage(plugin: plugin, registry: registry, target: target, find: find,
                        uiFontFamily: uiFontFamily, codeFontFamily: codeFontFamily,
                        locale: locale, isDark: colorScheme == .dark)
    }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.webView }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.configure(target: target, textScale: textScale, uiFontFamily: uiFontFamily,
                                      codeFontFamily: codeFontFamily, locale: locale, isDark: colorScheme == .dark)
        context.coordinator.setVisible(isVisible, find: find, scale: textScale)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: NectoPluginPage) { coordinator.invalidate() }
}

/// A document and its bridge have one lifetime, even when their presenting window changes.
@MainActor
final class NectoPluginPage {
    let webView: WKWebView
    private let bridge: NectoBridgeCoordinator
    private var invalidated = false

    init(plugin: NectoInstalledPlugin, registry: NectoPluginRegistry, target: NectoTarget?,
         find: NectoFindSession? = nil,
         uiFontFamily: String = NectoFontPreference.defaultUI,
         codeFontFamily: String = NectoFontPreference.defaultCode,
         locale: String = "en", isDark: Bool = false,
         websiteDataStore: WKWebsiteDataStore? = nil) {
        let originHost = plugin.principal.map(NectoPluginSchemeHandler.originHost(for:))
            ?? UUID().uuidString.lowercased()
        bridge = NectoBridgeCoordinator(plugin: plugin, originHost: originHost, registry: registry, target: target, find: find,
                                        uiFontFamily: uiFontFamily, codeFontFamily: codeFontFamily,
                                        locale: locale, isDarkAppearance: isDark)
        let controller = WKUserContentController()
        controller.addUserScript(NectoBridgeCoordinator.localeUserScript(locale))
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: NectoBridgeCoordinator.handlerName)
        let configuration = WKWebViewConfiguration()
        // Unregistered previews must not inherit or persist another installation's data.
        configuration.websiteDataStore = plugin.principal == nil ? .nonPersistent() : (websiteDataStore ?? .default())
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(
            NectoPluginSchemeHandler(originHost: originHost, archive: plugin.archive, allowedOrigins: plugin.manifest.allowedOrigins),
            forURLScheme: NectoPluginSchemeHandler.scheme
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = bridge
        bridge.webView = webView
        if let entryPoint = NectoPluginSchemeHandler.entryPointURL(originHost: originHost) {
            webView.load(URLRequest(url: entryPoint))
        }
    }

    func configure(target: NectoTarget?, textScale: CGFloat, uiFontFamily: String,
                   codeFontFamily: String, locale: String, isDark: Bool) {
        bridge.updateTarget(target)
        bridge.textScale = textScale
        bridge.uiFontFamily = uiFontFamily
        bridge.codeFontFamily = codeFontFamily
        bridge.locale = locale
        bridge.isDarkAppearance = isDark
    }

    func setVisible(_ visible: Bool, find: NectoFindSession?, scale: CGFloat) {
        if !visible {
            // Do not disturb another window or a control outside this document.
            if let window = webView.window, let responder = window.firstResponder as? NSView,
               responder === webView || responder.isDescendant(of: webView) {
                window.makeFirstResponder(nil)
            }
            bridge.find?.detach(webView)
            bridge.find = nil
        } else {
            if bridge.find !== find { bridge.find?.detach(webView) }
            bridge.find = find
            find?.attach(webView, scale: scale)
        }
        webView.isHidden = !visible
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        setVisible(false, find: nil, scale: 1)
        bridge.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: NectoBridgeCoordinator.handlerName)
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }
}

@MainActor
final class NectoBridgeCoordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let handlerName = "necto"

    private let plugin: NectoInstalledPlugin
    private let originHost: String
    private let registry: NectoPluginRegistry
    weak var find: NectoFindSession?
    private var target: NectoTarget?

    /// Stream events are buffered until `ready()` arrives.
    private var isReady = false
    private var bufferedEvents: [(subscriptionID: String, event: NectoJSONValue)] = []
    private var invokeTasks: [UUID: Task<Void, Never>] = [:]
    private var streamTasks: [String: Task<Void, Never>] = [:]
    private var nextSubscriptionNumber = 0
    private var recoveryTask: Task<Void, Never>?
    private var recentTerminations = 0
    private var lastTermination: ContinuousClock.Instant?
    /// Held rather than applied on the spot: the page it has to be set on may not have
    /// loaded yet, and a scale written to an empty web view is silently lost.
    var textScale: CGFloat = 1 {
        didSet { if textScale != oldValue { setTextScale(textScale) } }
    }
    var uiFontFamily: String {
        didSet { if uiFontFamily != oldValue { setFonts() } }
    }
    var codeFontFamily: String {
        didSet { if codeFontFamily != oldValue { setFonts() } }
    }
    var locale: String {
        didSet {
            guard locale != oldValue else { return }
            reloadForLocaleChange()
        }
    }
    var isDarkAppearance: Bool {
        didSet { if isDarkAppearance != oldValue { setAppearance() } }
    }

    weak var webView: WKWebView?

    init(
        plugin: NectoInstalledPlugin,
        originHost: String,
        registry: NectoPluginRegistry,
        target: NectoTarget?,
        find: NectoFindSession?,
        uiFontFamily: String,
        codeFontFamily: String,
        locale: String,
        isDarkAppearance: Bool
    ) {
        self.plugin = plugin
        self.originHost = originHost
        self.registry = registry
        self.target = target
        self.find = find
        self.uiFontFamily = uiFontFamily
        self.codeFontFamily = codeFontFamily
        self.locale = locale
        self.isDarkAppearance = isDarkAppearance
    }

    deinit {
        recoveryTask?.cancel()
        for task in invokeTasks.values { task.cancel() }
        for task in streamTasks.values { task.cancel() }
    }

    func invalidate() {
        recoveryTask?.cancel()
        recoveryTask = nil
        find?.detach(webView)
        resetPage()
        webView = nil
    }

    func updateTarget(_ target: NectoTarget?) {
        self.target = target
    }

    /// The page is the first thing that can hold the token, so this is the earliest the
    /// scale can be set — and the only chance, when the app starts at a size the user
    /// chose in an earlier session and nothing changes it afterwards.
    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        setAppearance()
        setTextScale(textScale)
        setFonts()
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        // A real navigation supersedes any delayed recovery of the previous document.
        recoveryTask?.cancel()
        recoveryTask = nil
        resetPage()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        resetPage()
        recoveryTask?.cancel()
        recoveryTask = nil
        let now = ContinuousClock().now
        if let lastTermination, now - lastTermination >= .seconds(60) {
            recentTerminations = 0
        }
        lastTermination = now
        recentTerminations += 1
        guard recentTerminations <= 3 else {
            NSLog("Necto: automatic recovery stopped for %@ after repeated content-process termination. Disable and enable the plugin to retry.", plugin.id)
            return
        }
        let delay = 1 << (recentTerminations - 1)
        recoveryTask = Task { [weak self, weak webView] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self, let webView, self.webView === webView else { return }
            self.recoveryTask = nil
            // WebKit defers its default recovery while hidden. Background plugins
            // must recreate their document without waiting for a selected panel.
            webView.reload()
        }
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let trusted = url?.scheme == NectoPluginSchemeHandler.scheme && url?.host == originHost
        decisionHandler(trusted ? .allow : .cancel)
        if !trusted, navigationAction.navigationType == .linkActivated,
           navigationAction.sourceFrame.isMainFrame,
           let url, ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil {
            NSWorkspace.shared.open(url)
        }
    }

    static func localeUserScript(_ locale: String) -> WKUserScript {
        WKUserScript(
            source: "document.documentElement.lang = \(jsLiteral(locale));",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    private func reloadForLocaleChange() {
        guard let webView else { return }
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.addUserScript(Self.localeUserScript(locale))
        webView.reload()
    }

    private func resetPage() {
        isReady = false
        bufferedEvents.removeAll()
        for task in invokeTasks.values { task.cancel() }
        invokeTasks.removeAll()
        for task in streamTasks.values { task.cancel() }
        streamTasks.removeAll()
    }

    /// A device plugin carries the stylesheet from the app that built it. Reasserting
    /// the host-owned tokens keeps an older carried panel aligned with the current shell.
    private func setAppearance() {
        let theme = isDarkAppearance ? "dark" : "light"
        let surface = isDarkAppearance ? "var(--necto-base-10)" : "var(--necto-base-05)"
        evaluate("""
        document.documentElement.dataset.theme = '\(theme)';
        document.documentElement.style.setProperty('--light-00', '#ffffff');
        document.documentElement.style.setProperty('--light-05', '#fcfcfc');
        document.documentElement.style.setProperty('--light-10', '#f6f7f6');
        document.documentElement.style.setProperty('--light-20', '#eff1f0');
        document.documentElement.style.setProperty('--light-30', '#e5e5e5');
        document.documentElement.style.setProperty('--necto-surface', '\(surface)');
        """)
    }

    private func setTextScale(_ scale: CGFloat) {
        evaluate(
            "document.documentElement.style.setProperty('--necto-font-scale', '\(scale)')"
        )
    }

    private func setFonts() {
        let ui = uiFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = codeFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUI = ui.isEmpty ? NectoFontPreference.defaultUI : ui
        let resolvedCode = code.isEmpty ? NectoFontPreference.defaultCode : code
        evaluate("""
        document.documentElement.style.setProperty('--necto-font', \(Self.jsLiteral(resolvedUI)));
        document.documentElement.style.setProperty('--necto-font-ui', \(Self.jsLiteral(resolvedUI)));
        document.documentElement.style.setProperty('--necto-font-mono', \(Self.jsLiteral(resolvedCode)));
        """)
    }

    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == NectoPluginSchemeHandler.scheme,
              message.frameInfo.request.url?.host == originHost,
              message.webView === webView else {
            replyHandler(nil, "The native bridge is only available to the installed plugin's main document")
            return
        }
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else {
            replyHandler(Self.failureReply(.init(code: .invalidInput, message: "Malformed request")), nil)
            return
        }

        let id = UUID()
        invokeTasks[id] = Task { [weak self] in
            guard let self else { return }
            let reply = await handle(type: type, body: body)
            invokeTasks.removeValue(forKey: id)
            guard !Task.isCancelled else { return }
            replyHandler(reply, nil)
        }
    }

    private func handle(type: String, body: [String: Any]) async -> [String: Any] {
        switch type {
        case "context":
            let context = await registry.context(
                pluginID: plugin.manifest.id,
                target: target,
                expectedPrincipal: plugin.principal
            )
            return Self.successReply(context)

        case "ready":
            isReady = true
            let buffered = bufferedEvents
            bufferedEvents.removeAll()
            for entry in buffered {
                deliver(subscriptionID: entry.subscriptionID, event: entry.event)
            }
            return Self.successReply(NectoJSONValue.null)

        case "invoke":
            guard let operationID = body["operationID"] as? String else {
                return Self.failureReply(.init(code: .invalidInput, message: "operationID is missing"))
            }
            do {
                let output = try await registry.invoke(
                    pluginID: plugin.manifest.id,
                    operationID: operationID,
                    input: Self.jsonValue(from: body["input"]),
                    target: target,
                    expectedPrincipal: plugin.principal
                )
                return Self.successReply(output)
            } catch {
                return Self.failureReply(Self.bridgeError(from: error, operationID: operationID))
            }

        case "subscribe":
            guard let operationID = body["operationID"] as? String else {
                return Self.failureReply(.init(code: .invalidInput, message: "operationID is missing"))
            }
            return await startSubscription(operationID: operationID, body: body)

        case "unsubscribe":
            if let subscriptionID = body["subscriptionID"] as? String {
                streamTasks.removeValue(forKey: subscriptionID)?.cancel()
            }
            return Self.successReply(NectoJSONValue.null)

        default:
            return Self.failureReply(.init(code: .operationNotFound, message: "Unknown request '\(type)'"))
        }
    }

    private func startSubscription(operationID: String, body: [String: Any]) async -> [String: Any] {
        nextSubscriptionNumber += 1
        let subscriptionID = "s\(nextSubscriptionNumber)"

        do {
            let stream = try await registry.subscribe(
                pluginID: plugin.manifest.id,
                operationID: operationID,
                input: Self.jsonValue(from: body["input"]),
                target: target,
                expectedPrincipal: plugin.principal
            )

            streamTasks[subscriptionID] = Task { [weak self] in
                do {
                    for try await event in stream {
                        guard !Task.isCancelled else { return }
                        self?.emit(subscriptionID: subscriptionID, event: event)
                    }
                    self?.finish(subscriptionID: subscriptionID)
                } catch {
                    self?.fail(
                        subscriptionID: subscriptionID,
                        error: Self.bridgeError(from: error, operationID: operationID)
                    )
                }
            }
            return Self.successReply(NectoJSONValue.string(subscriptionID))
        } catch {
            return Self.failureReply(Self.bridgeError(from: error, operationID: operationID))
        }
    }

    private func emit(subscriptionID: String, event: NectoJSONValue) {
        guard isReady else {
            bufferedEvents.append((subscriptionID, event))
            return
        }
        deliver(subscriptionID: subscriptionID, event: event)
    }

    private func finish(subscriptionID: String) {
        streamTasks.removeValue(forKey: subscriptionID)
        evaluate("window.__nectoBridgeStreamEnd?.(\(Self.jsLiteral(subscriptionID)))")
    }

    private func fail(subscriptionID: String, error: NectoBridgeError) {
        streamTasks.removeValue(forKey: subscriptionID)
        evaluate("window.__nectoBridgeStreamError?.(\(Self.jsLiteral(subscriptionID)), \(Self.jsObject(error)))")
    }

    private func deliver(subscriptionID: String, event: NectoJSONValue) {
        evaluate("window.__nectoBridgeDeliver?.(\(Self.jsLiteral(subscriptionID)), \(Self.jsObject(event)))")
    }

    /// Replies are plain JSON objects so error codes survive the WebKit boundary.
    private static func successReply(_ value: some Encodable) -> [String: Any] {
        ["ok": true, "value": foundationObject(value) ?? NSNull()]
    }

    private static func failureReply(_ error: NectoBridgeError) -> [String: Any] {
        ["ok": false, "error": foundationObject(error) ?? NSNull()]
    }

    private static func foundationObject(_ value: some Encodable) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script)
    }

    private static func bridgeError(from error: any Error, operationID: String) -> NectoBridgeError {
        if let error = error as? NectoBridgeError { return error }
        return NectoBridgeError(
            code: .providerFailed,
            message: String(describing: error),
            operationID: operationID
        )
    }

    private static func jsonValue(from raw: Any?) -> NectoJSONValue {
        guard let raw,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let value = try? JSONDecoder().decode(NectoJSONValue.self, from: data)
        else { return .object([:]) }
        return value
    }

    private static func jsObject(_ value: some Encodable) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    private static func jsLiteral(_ text: String) -> String {
        jsObject(text)
    }
}
