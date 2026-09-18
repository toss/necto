//
// Copyright (c) 2026 Viva Republica, Inc.
//
import Foundation
import NectoMacService
import NectoModel
import WebKit
import Testing

private struct SecurityCheckFailed: Error { let message: String }

private struct ErrorTicksProvider: NectoOperationProvider {
    static let message = "<img src=missing onerror=window.injected=true> & <script>window.injected=true</script>"
    let descriptor = NectoBridgeDescriptor(binding: .init(name: "necto.desktop.ticks", version: 1), kind: .stream)

    func subscribe(input: NectoJSONValue, context: NectoInvocationContext) async throws
        -> AsyncThrowingStream<NectoJSONValue, any Error> {
        throw NectoBridgeError(code: .providerFailed, message: Self.message)
    }
}

@Suite("WebView security", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoWebViewSecurityTests {
    @Test("App and installation identities isolate storage while trusted updates retain it")
    func storageIsolation() async throws {
        // Share one store so origin collisions expose another principal's data.
        try await Self.verifyStorageIsolation(dataStore: .nonPersistent())
    }

    static func wait(_ page: NectoPluginPage, for expression: String) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if (try? await page.webView.evaluateJavaScript(expression) as? Bool) == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SecurityCheckFailed(message: "Timed out: \(expression)")
    }

    static func fixture(id: String, source: NectoInstalledPlugin.Source,
                        installation: NectoLocalPluginInstallation? = nil, version: String = "1.0.0") -> NectoInstalledPlugin {
        let manifest = NectoPluginManifest(id: id, name: "Storage fixture", description: "Synthetic fixture",
            version: version, author: "Example", icon: .init(systemName: "testtube.2"),
            assets: ["index.html", "frame.html"], allowedOrigins: ["self"], operations: [])
        let archive = NectoPanelArchive(files: [
            .init(path: "index.html", data: Data("<html><body>\(version)<script>window.loaded=true</script></body></html>".utf8)),
            .init(path: "frame.html", data: Data("<script>window.webkit.messageHandlers.necto.postMessage({type:'context'}).then(()=>parent.frameResult='allowed').catch(()=>parent.frameResult='denied')</script>".utf8)),
        ])
        return NectoInstalledPlugin(manifest: manifest, rootURL: URL(filePath: NSTemporaryDirectory()),
            source: source, archive: archive, contentIdentity: archive.contentHash, installation: installation)
    }

    private static func open(_ plugin: NectoInstalledPlugin, dataStore: WKWebsiteDataStore) async throws -> NectoPluginPage {
        let registry = NectoPluginRegistry()
        if let principal = plugin.principal {
            try await registry.install(manifest: plugin.manifest, sourceIdentity: principal.sourceIdentity)
        }
        let page = NectoPluginPage(plugin: plugin, registry: registry, target: nil, websiteDataStore: dataStore)
        do { try await Self.wait(page, for: "window.loaded === true"); return page }
        catch { page.invalidate(); throw error }
    }

    private static func verifyStorageIsolation(dataStore: WKWebsiteDataStore) async throws {
        func open(_ plugin: NectoInstalledPlugin) async throws -> NectoPluginPage {
            try await Self.open(plugin, dataStore: dataStore)
        }
        let id = "com.example.storage-" + UUID().uuidString.lowercased()
        let source = NectoInstalledPlugin.Source.device(appName: "A", appBundleID: "com.example.a")
        let first = fixture(id: id, source: source)
        var pages: [NectoPluginPage] = []
        defer { for page in pages { page.invalidate() } }
        let a = try await open(first)
        pages.append(a)
        _ = try await a.webView.evaluateJavaScript("localStorage.setItem('sentinel', 'A')")
        try #require(a.webView.url?.host != id, "Legacy plugin-ID origin was reused")

        let b = try await open(fixture(id: id, source: .device(appName: "B", appBundleID: "com.example.b")))
        pages.append(b)
        let isolated = try await b.webView.evaluateJavaScript("localStorage.getItem('sentinel') === null") as? Bool
        try #require(isolated == true, "Another app inherited browser storage")

        let updated = fixture(id: id, source: source, version: "2.0.0")
        try #require(first.contentIdentity != updated.contentIdentity, "Update fixture did not change content")
        a.invalidate()
        let reopened = try await open(updated)
        pages.append(reopened)
        let retained = try await reopened.webView.evaluateJavaScript("localStorage.getItem('sentinel')") as? String
        try #require(retained == "A", "Update lost the same principal's browser storage")
        _ = try await reopened.webView.evaluateJavaScript("localStorage.removeItem('sentinel')")

        let local = NectoLocalPluginInstallation(pluginID: id, directoryPath: "/synthetic", approvedContentHash: "first")
        let desktop = try await open(fixture(id: id, source: .installed, installation: local))
        pages.append(desktop)
        _ = try await desktop.webView.evaluateJavaScript("localStorage.setItem('sentinel', 'desktop')")
        var approvedUpdate = local
        approvedUpdate.approveUpdate(contentHash: "second", origin: nil)
        desktop.invalidate()
        let desktopUpdate = try await open(fixture(id: id, source: .installed, installation: approvedUpdate, version: "2.0.0"))
        pages.append(desktopUpdate)
        let desktopRetained = try await desktopUpdate.webView.evaluateJavaScript("localStorage.getItem('sentinel')") as? String
        try #require(desktopRetained == "desktop", "Local update lost browser storage")

        let reinstalled = NectoLocalPluginInstallation(pluginID: id, directoryPath: "/synthetic", approvedContentHash: "second")
        let desktopNew = try await open(fixture(id: id, source: .installed, installation: reinstalled))
        pages.append(desktopNew)
        let clean = try await desktopNew.webView.evaluateJavaScript("localStorage.getItem('sentinel') === null") as? Bool
        try #require(clean == true, "Reinstallation inherited the previous UUID's storage")
        _ = try await desktopUpdate.webView.evaluateJavaScript("localStorage.removeItem('sentinel')")

        let preview = try await open(fixture(id: id, source: .installed))
        pages.append(preview)
        try #require(!preview.webView.configuration.websiteDataStore.isPersistent, "Unregistered preview persisted storage")
        try #require(preview.webView.configuration.websiteDataStore !== dataStore, "Unregistered preview inherited the shared store")
    }

    @Test("Principal fields produce distinct storage origins")
    func distinctOrigins() throws {
        let principal = NectoPluginPrincipal(pluginID: "com.example.storage", sourceIdentity: "device:com.example.a")
        let otherID = NectoPluginPrincipal(pluginID: principal.pluginID + "-other", sourceIdentity: principal.sourceIdentity)
        try #require(NectoPluginSchemeHandler.originHost(for: principal) != NectoPluginSchemeHandler.originHost(for: otherID),
                    "Different plugin IDs shared an origin")
        try #require(NectoPluginSchemeHandler.originHost(for: .init(pluginID: "bc", sourceIdentity: "a")) !=
                    NectoPluginSchemeHandler.originHost(for: .init(pluginID: "c", sourceIdentity: "ab")),
                    "Ambiguous principal fields shared an origin")
    }

    @Test("The main frame can access the bridge while iframes cannot")
    func bridgeIsolation() async throws {
        let plugin = Self.fixture(id: "com.example.bridge-" + UUID().uuidString.lowercased(),
                                  source: .device(appName: "A", appBundleID: "com.example.a"))
        let page = try await Self.open(plugin, dataStore: .nonPersistent())
        defer { page.invalidate() }
        _ = try await page.webView.evaluateJavaScript("window.webkit.messageHandlers.necto.postMessage({type:'context'}).then(r=>window.mainResult=r.ok); void 0")
        try await Self.wait(page, for: "window.mainResult === true")
        _ = try await page.webView.evaluateJavaScript("const frame=document.createElement('iframe'); frame.src='frame.html'; document.body.append(frame)")
        try await Self.wait(page, for: "window.frameResult === 'denied'")
    }

    @Test("Provider errors render as text without executing HTML")
    func sampleErrors() async throws {
        try await Self.verifySampleErrors(dataStore: .nonPersistent())
    }

    private static func verifySampleErrors(dataStore: WKWebsiteDataStore) async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WebPackages/BuiltInPlugins/Plugins/plugin-sample")
        let plugin = try NectoPluginLoader.load(from: root, source: .device(appName: "Fixture", appBundleID: "com.example.error-fixture"))
        let registry = NectoPluginRegistry()
        try await registry.install(manifest: plugin.manifest, sourceIdentity: "device:com.example.error-fixture")
        await registry.registerHostProvider(ErrorTicksProvider())
        let page = NectoPluginPage(plugin: plugin, registry: registry, target: nil, websiteDataStore: dataStore)
        defer { page.invalidate() }
        try await Self.wait(page, for: "document.querySelector('#info-status .necto-status-danger') !== null")
        for count in 1...5 {
            _ = try await page.webView.evaluateJavaScript("window.previousNotice=document.querySelector('#failures .necto-notice'); document.getElementById('start-ticks').click()")
            try await Self.wait(page, for: "document.querySelector('#failures .necto-notice') !== window.previousNotice && document.querySelectorAll('#failures .necto-notice').length === \(min(count, 4))")
        }
        let message = try await page.webView.evaluateJavaScript("document.querySelector('#failures p').textContent") as? String
        try #require(message == ErrorTicksProvider.message, "Error message was not displayed literally")
        let safe = try await page.webView.evaluateJavaScript("!window.injected && document.querySelectorAll('#failures img, #failures script').length === 0") as? Bool
        try #require(safe == true, "Provider error created executable HTML")
    }
}
