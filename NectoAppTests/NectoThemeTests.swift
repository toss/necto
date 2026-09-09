//
// Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoMacService
import NectoModel
import SwiftUI
import Testing

@Suite("Rendered design tokens", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoThemeTests {
    @Test("Shared and shipped styles match native colors in both appearances", arguments: [false, true])
    func renderedColors(isDark: Bool) async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panelRoot = root.appending(path: "Sources/NectoDefaultPlugins/Panels")
        let panels = try FileManager.default.contentsOfDirectory(at: panelRoot, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }.map { $0.appending(path: "assets/index.css") }
        let styles = [root.appending(path: "WebPackages/Bridge/theme.css")] + panels + [
            root.appending(path: "WebPackages/BuiltInPlugins/Plugins/plugin-sample/assets/index.css"),
            root.appending(path: "WebPackages/BuiltInPlugins/Plugins/shell-demo/assets/index.css"),
        ]
        for style in styles {
            try await checkColors(css: String(contentsOf: style, encoding: .utf8), isDark: isDark, label: style.path)
        }
    }

    @Test("The host refreshes neutral tokens carried by an older panel", arguments: [false, true])
    func refreshesOlderTokens(isDark: Bool) async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let css = try String(contentsOf: root.appending(path: "WebPackages/Bridge/theme.css"), encoding: .utf8)
        try await checkColors(css: css + """
            :root {
              --light-00: #000000; --light-05: #000000; --light-10: #000000;
              --light-20: #000000; --light-30: #000000; --necto-surface: #000000;
            }
            """, isDark: isDark, label: "Older carried tokens")
    }

    private func checkColors(css: String, isDark: Bool, label: String) async throws {
        let manifest = NectoPluginManifest(
            id: "com.example.theme", name: "Theme fixture", description: "Rendered token comparison",
            version: "1.0.0", author: "Necto tests", icon: .init(systemName: "circle"),
            assets: ["index.html", "theme.css"], allowedOrigins: ["self"], operations: []
        )
        let archive = NectoPanelArchive(files: [
            .init(path: "index.html", data: Data("<html><head><link rel=stylesheet href=theme.css></head><body></body></html>".utf8)),
            .init(path: "theme.css", data: Data(css.utf8)),
        ])
        let plugin = NectoInstalledPlugin(manifest: manifest, rootURL: URL(filePath: NSTemporaryDirectory()),
            source: .installed, archive: archive, contentIdentity: archive.contentHash)
        let page = NectoPluginPage(plugin: plugin, registry: NectoPluginRegistry(), target: nil, isDark: isDark)
        defer { page.invalidate() }
        let theme = isDark ? "dark" : "light"
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if (try? await page.webView.evaluateJavaScript("document.documentElement.dataset.theme === '\(theme)'") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let tokens: [(String, Color)] = [
            ("bg", NectoTheme.background), ("sidebar", NectoTheme.sidebar), ("surface", NectoTheme.surface),
            ("hover", NectoTheme.hover), ("selected", NectoTheme.selected), ("border", NectoTheme.border),
            ("border-strong", NectoTheme.borderStrong), ("text", NectoTheme.text),
            ("text-secondary", NectoTheme.textSecondary), ("text-tertiary", NectoTheme.textTertiary),
            ("accent", NectoTheme.accent), ("brand", NectoTheme.brand), ("success", NectoTheme.success),
            ("warning", NectoTheme.warning), ("danger", NectoTheme.danger), ("info", NectoTheme.info),
        ]
        let loadedTheme = try await page.webView.evaluateJavaScript("document.documentElement.dataset.theme") as? String
        try #require(loadedTheme == theme, "Host appearance was not applied")
        for (token, color) in tokens {
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance { resolved = NSColor(color).usingColorSpace(.sRGB) }
            let native = try #require(resolved)
            let rgb = [native.redComponent, native.greenComponent, native.blueComponent].map { Int(($0 * 255).rounded()) }
            let expected = "rgb(\(rgb[0]), \(rgb[1]), \(rgb[2]))"
            let rendered = try await page.webView.evaluateJavaScript("""
                (() => {
                  const probe = document.createElement('span');
                  probe.style.color = 'var(--necto-\(token))';
                  document.body.append(probe);
                  const color = getComputedStyle(probe).color;
                  probe.remove();
                  return color;
                })()
                """) as? String
            #expect(rendered == expected, "\(label): --necto-\(token) in \(theme)")
        }
    }
}
