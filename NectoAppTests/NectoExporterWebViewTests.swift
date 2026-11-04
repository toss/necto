//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel
import Testing
import WebKit

@Suite("Event exporter WebView", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoExporterWebViewTests {
    private func fixture(type: NectoPluginType? = .eventExporter,
                         installed: Bool = true) -> NectoInstalledPlugin {
        let id = "com.example.exporter-" + UUID().uuidString.lowercased()
        let manifest = NectoPluginManifest(type: type, id: id, name: "Exporter fixture", description: "Local test",
            version: "1.0.0", author: "Example", icon: .init(systemName: "testtube.2"),
            assets: ["index.html"], allowedOrigins: ["self"], operations: [])
        let archive = NectoPanelArchive(files: [.init(path: "index.html", data: Data("""
        <html><script>
        window.events = [];
        window.__nectoExporterReceive = event => window.events.push(event);
        window.loaded = true;
        </script></html>
        """.utf8))])
        let root = URL(filePath: NSTemporaryDirectory()).appendingPathComponent(id)
        let installation = installed ? NectoLocalPluginInstallation(pluginID: id, directoryPath: root.path,
                                                                     approvedContentHash: archive.contentHash) : nil
        return NectoInstalledPlugin(manifest: manifest, rootURL: root, source: .installed,
            archive: archive, contentIdentity: archive.contentHash, installation: installation)
    }

    private func request(_ page: NectoPluginPage, _ json: String) async throws -> [String: Any] {
        // WKWebView's evaluateJavaScript cannot await a Promise. callAsyncJavaScript can.
        let result = try await page.webView.callAsyncJavaScript(
            "return await window.webkit.messageHandlers.necto.postMessage(\(json));",
            arguments: [:], in: nil, contentWorld: .page)
        return try #require(result as? [String: Any])
    }

    @Test("Hidden exporter receives allowed events in order and diagnostics stay local")
    func receivesAndDiagnoses() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "test-installation", nectoVersion: "1.0.0")
        let diagnostics = NectoDiagnosticsLog()
        let plugin = fixture()
        #expect(plugin.runsInBackground)
        let page = NectoPluginPage(plugin: plugin, registry: NectoPluginRegistry(), target: nil,
                                  websiteDataStore: .nonPersistent(), eventDispatcher: dispatcher, diagnostics: diagnostics)
        defer { page.invalidate() }
        page.setVisible(false, find: nil, scale: 1)
        try await NectoWebViewSecurityTests.wait(page, for: "window.loaded === true")
        await dispatcher.record(try .init(eventName: "before.registration"), source: .necto())
        #expect(try await request(page, "{type:'registerExporter'}")["ok"] as? Bool == true)
        #expect(try await request(page, "{type:'registerExporter'}")["ok"] as? Bool == false)
        await dispatcher.updatePolicy(.init(excludedPluginIDs: ["com.example.excluded"]))
        await dispatcher.record(try .init(eventName: "excluded"), source: .desktop(id: "com.example.excluded", version: "1.0.0"))
        for index in 0..<5 {
            await dispatcher.record(try .init(eventName: "event.\(index)"), source: .necto(), channel: .ui)
        }
        try await NectoWebViewSecurityTests.wait(page, for: "window.events.length === 5")
        let names = try await page.webView.evaluateJavaScript("window.events.map(e => e.eventName).join(',')") as? String
        #expect(names == "event.0,event.1,event.2,event.3,event.4")
        #expect(try await request(page, "{type:'diagnostic',level:'warning',message:'Retry scheduled',metadata:{attempt:2}}")["ok"] as? Bool == true)
        let entry = await diagnostics.recent().first
        #expect(entry?.source == .exporter)
        #expect(entry?.severity == .warning)
        #expect(entry?.message == "Retry scheduled")
        #expect(entry?.detail?.contains(plugin.id) == true)
        #expect(entry?.detail?.contains("\"attempt\":2") == true)
        #expect(try await page.webView.evaluateJavaScript("window.events.length") as? Int == 5)
        #expect(try await request(page, "{type:'diagnostic',level:'warning',message:'Invalid',metadata:[]}")["ok"] as? Bool == false)
    }

    @Test("Ordinary plugins and uninstalled previews cannot register or write exporter diagnostics")
    func rejectsOtherPages() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "test-installation", nectoVersion: "1.0.0")
        for plugin in [fixture(type: nil), fixture(installed: false)] {
            let page = NectoPluginPage(plugin: plugin, registry: NectoPluginRegistry(), target: nil,
                                      websiteDataStore: .nonPersistent(), eventDispatcher: dispatcher,
                                      diagnostics: NectoDiagnosticsLog())
            defer { page.invalidate() }
            try await NectoWebViewSecurityTests.wait(page, for: "window.loaded === true")
            #expect(try await request(page, "{type:'registerExporter'}")["ok"] as? Bool == false)
            #expect(try await request(page, "{type:'diagnostic',level:'info',message:'Not allowed'}")["ok"] as? Bool == false)
        }
    }

    @Test("Reload unregisters the old document and removal frees the single receiver")
    func reloadAndRemove() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "test-installation", nectoVersion: "1.0.0")
        let page = NectoPluginPage(plugin: fixture(), registry: NectoPluginRegistry(), target: nil,
                                  websiteDataStore: .nonPersistent(), eventDispatcher: dispatcher)
        defer { page.invalidate() }
        try await NectoWebViewSecurityTests.wait(page, for: "window.loaded === true")
        #expect(try await request(page, "{type:'registerExporter'}")["ok"] as? Bool == true)
        _ = try await page.webView.evaluateJavaScript("window.loaded = false")
        page.webView.reload()
        try await NectoWebViewSecurityTests.wait(page, for: "window.loaded === true")
        #expect(try await request(page, "{type:'registerExporter'}")["ok"] as? Bool == true)
        page.invalidate()
        let deadline = ContinuousClock.now + .seconds(3)
        var replacement: UUID?
        while replacement == nil, ContinuousClock.now < deadline {
            replacement = try? await dispatcher.registerExporter { _ in }
            if replacement == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let registration = try #require(replacement)
        await dispatcher.unregisterExporter(registrationID: registration)
    }
}
