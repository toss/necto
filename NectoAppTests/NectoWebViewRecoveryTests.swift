//
// Copyright (c) 2026 Viva Republica, Inc.
//
import AppKit
import Foundation
import NectoMacService
import NectoModel
import WebKit
import Testing

private struct CheckFailed: Error { let message: String }

@Suite("WebView recovery", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoWebViewRecoveryTests {
    private func page() -> NectoPluginPage {
        let id = "com.example.recovery-" + UUID().uuidString.lowercased()
        let manifest = NectoPluginManifest(id: id, name: "Recovery fixture", description: "Local fixture",
            version: "1.0.0", author: "Necto", icon: .init(systemName: "testtube.2"),
            assets: ["index.html"], allowedOrigins: ["self"], operations: [])
        let archive = NectoPanelArchive(files: [.init(path: "index.html",
            data: Data("<html><script>window.fixtureLoad = Math.random().toString(36);</script></html>".utf8))])
        let plugin = NectoInstalledPlugin(manifest: manifest, rootURL: URL(filePath: NSTemporaryDirectory()),
            source: .installed, archive: archive, contentIdentity: archive.contentHash)
        let page = NectoPluginPage(plugin: plugin, registry: NectoPluginRegistry(), target: nil)
        page.setVisible(false, find: nil, scale: 1)
        return page
    }

    private func loaded(_ view: WKWebView, after previous: String? = nil, seconds: Double = 8) async throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let marker = try? await view.evaluateJavaScript("window.fixtureLoad") as? String,
               marker != previous { return marker }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CheckFailed(message: "A hidden plugin did not reload after content-process termination")
    }

    @Test("Hidden panels reload after termination, stop retrying, and cancel recovery on removal")
    func recoversAndInvalidates() async throws {
        let first = page()
        defer { first.invalidate() }
        var marker = try await loaded(first.webView)
        try #require(first.webView.window == nil && first.webView.isHidden, "Fixture must remain hidden")
        // Inject the delegate event; do not kill any user-owned WebKit process.
        for _ in 0..<3 {
            first.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(first.webView)
            marker = try await loaded(first.webView, after: marker)
        }
        first.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(first.webView)
        // An uncapped fourth exponential retry would run after eight seconds.
        try await Task.sleep(for: .milliseconds(8500))
        let afterLimit = try await first.webView.evaluateJavaScript("window.fixtureLoad") as? String
        #expect(afterLimit == marker, "Repeated crashes exceeded the automatic recovery limit")

        let removed = page()
        defer { removed.invalidate() }
        _ = try await loaded(removed.webView)
        removed.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(removed.webView)
        removed.invalidate()
        try await Task.sleep(for: .milliseconds(1500))
        #expect(removed.webView.navigationDelegate == nil, "Removed page retained its delegate")
        #expect(removed.webView.url?.scheme != NectoPluginSchemeHandler.scheme,
                    "Pending recovery reloaded a removed plugin")
    }
}
