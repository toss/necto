//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel
import Testing
import WebKit

@Suite("Event exporter shutdown", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoExporterShutdownTests {
    @Test("Shutdown drains accepted events, stops delivery, and awaits the hook's storage write")
    func drainsEventsAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = NectoPluginStorage(directory: directory)
        let operation = NectoOperation(id: "persist", title: "Persist", description: "Save a synthetic value",
            kind: .once, binding: .init(name: NectoStorageSetProvider.key, version: 1),
            inputSchema: [
                "type": "object", "required": ["key", "value", "scope"],
                "properties": ["key": ["type": "string"], "value": ["type": "string"], "scope": ["type": "string"]],
            ],
            outputSchema: [
                "type": "object", "required": ["success"], "properties": ["success": ["type": "boolean"]],
            ], timeoutMs: 10_000)
        let fixture = Fixture(operations: [operation], script: """
            window.__nectoExporterShutdown = async ({deadlineAt}) => {
                window.shutdownDeadline = deadlineAt;
                window.acceptedAtShutdown = window.events.join(',');
                await new Promise(resolve => { window.releaseShutdown = resolve; });
                const reply = await window.webkit.messageHandlers.necto.postMessage({
                    type: 'invoke', operationID: 'persist',
                    input: {key: 'checkpoint', value: window.acceptedAtShutdown, scope: 'plugin'}
                });
                if (!reply.ok) throw new Error('Could not persist the checkpoint');
            };
            """)
        await fixture.registry.registerHostProvider(NectoStorageSetProvider(storage: storage))
        let page = try await fixture.open()
        defer { page.invalidate() }

        for index in 0..<5 {
            await fixture.dispatcher.record(try .init(eventName: "accepted.\(index)"), source: .necto())
        }

        let earliestDeadline = Date().addingTimeInterval(5).timeIntervalSince1970 * 1000
        let shutdown = Task { await fixture.runtime.shutdown() }
        try await NectoWebViewSecurityTests.wait(page, for: "typeof window.releaseShutdown === 'function'")
        let latestDeadline = Date().addingTimeInterval(5).timeIntervalSince1970 * 1000
        let deadline = try #require(try await page.webView.evaluateJavaScript("window.shutdownDeadline") as? Double)
        #expect(deadline >= earliestDeadline - 1 && deadline <= latestDeadline + 1)
        let accepted = "accepted.0,accepted.1,accepted.2,accepted.3,accepted.4"
        #expect(try await page.webView.evaluateJavaScript("window.acceptedAtShutdown") as? String == accepted)

        await fixture.dispatcher.record(try .init(eventName: "after.cutoff"), source: .necto())
        // A free receiver slot proves the dispatcher detached the page before the hook finished.
        let probe = try await fixture.dispatcher.registerExporter { _ in }
        await fixture.dispatcher.unregisterExporter(registrationID: probe)
        #expect(try await Self.registerExporter(page) == false)
        #expect(try await page.webView.evaluateJavaScript("window.events.join(',')") as? String == accepted)

        fixture.synchronize(exporter: fixture.exporter)
        #expect(fixture.runtime.page === page)
        _ = try await page.webView.evaluateJavaScript("window.releaseShutdown(); undefined")
        await shutdown.value

        #expect(fixture.runtime.page == nil)
        #expect(page.webView.navigationDelegate == nil)
        let principal = try #require(fixture.exporter.principal)
        let scope = NectoPluginStorage.Scope(principal: principal, target: nil, isPluginWide: true)
        let reopened = NectoPluginStorage(directory: directory)
        #expect(await reopened.value(forKey: "checkpoint", scope: scope) == .string(accepted))
        fixture.synchronize(exporter: fixture.exporter)
        #expect(fixture.runtime.page == nil)
    }

    @Test("Removal still ends the exporter immediately while normal shutdown is pending")
    func removalDuringShutdown() async throws {
        let fixture = Fixture(script: """
            window.__nectoExporterShutdown = async () => {
                window.shutdownPending = true;
                await new Promise(resolve => setTimeout(resolve, 12000));
            };
            """)
        let page = try await fixture.open()
        defer { page.invalidate() }
        let shutdown = Task { await fixture.runtime.shutdown() }
        try await NectoWebViewSecurityTests.wait(page, for: "window.shutdownPending === true")

        let start = ContinuousClock.now
        fixture.synchronize(exporter: nil)
        await shutdown.value
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(fixture.runtime.page == nil)
        #expect(page.webView.navigationDelegate == nil)
        fixture.synchronize(exporter: fixture.exporter)
        #expect(fixture.runtime.page == nil)
    }

    @Test("A rejected hook tears down the WebView without waiting for the timeout")
    func rejectedHook() async throws {
        let fixture = Fixture(script: """
            window.__nectoExporterShutdown = async () => {
                await window.webkit.messageHandlers.necto.postMessage({
                    type: 'diagnostic', level: 'info', message: 'Reached failing shutdown hook'
                });
                throw new Error('Synthetic shutdown failure');
            };
            """)
        let page = try await fixture.open()
        defer { page.invalidate() }

        let start = ContinuousClock.now
        await fixture.runtime.shutdown()
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(fixture.runtime.page == nil)
        #expect(page.webView.navigationDelegate == nil)
        let entries = await fixture.diagnostics.recent()
        #expect(entries.contains { $0.message == "Reached failing shutdown hook" })
    }

    @Test("A missing hook completes promptly")
    func missingHook() async throws {
        let fixture = Fixture()
        let page = try await fixture.open()
        defer { page.invalidate() }

        let start = ContinuousClock.now
        await fixture.runtime.shutdown()
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(fixture.runtime.page == nil)
        #expect(page.webView.navigationDelegate == nil)
    }

    @Test("An empty runtime completes promptly")
    func noExporter() async {
        let runtime = NectoExporterRuntime()
        let start = ContinuousClock.now
        await runtime.shutdown()
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(runtime.page == nil)
    }

    @Test("Concurrent shutdown requests share one hook and the five-second timeout")
    func timesOutOnce() async throws {
        let fixture = Fixture(script: """
            window.__nectoExporterShutdown = async () => {
                await window.webkit.messageHandlers.necto.postMessage({
                    type: 'diagnostic', level: 'info', message: 'Reached stalled shutdown hook'
                });
                // Bound the fixture too so a broken host timeout fails the test instead of hanging it.
                await new Promise(resolve => {
                    window.shutdownPending = true;
                    setTimeout(resolve, 12000);
                });
            };
            """)
        let page = try await fixture.open()
        defer { page.invalidate() }

        let start = ContinuousClock.now
        let first = Task {
            await fixture.runtime.shutdown()
            return ContinuousClock.now - start
        }
        try await NectoWebViewSecurityTests.wait(page, for: "window.shutdownPending === true")
        let second = Task {
            #expect(fixture.runtime.page === page)
            await fixture.runtime.shutdown()
            return ContinuousClock.now - start
        }

        let elapsedTimes = await [first.value, second.value]
        for elapsed in elapsedTimes {
            #expect(elapsed >= .milliseconds(4900) && elapsed < .seconds(8))
        }
        #expect(fixture.runtime.page == nil)
        #expect(page.webView.navigationDelegate == nil)
        let entries = await fixture.diagnostics.recent()
        #expect(entries.filter { $0.message == "Reached stalled shutdown hook" }.count == 1)

        let repeatStart = ContinuousClock.now
        await fixture.runtime.shutdown()
        #expect(ContinuousClock.now - repeatStart < .seconds(3))
    }

    @MainActor
    private struct Fixture {
        let runtime = NectoExporterRuntime()
        let registry = NectoPluginRegistry()
        let dispatcher = NectoEventDispatcher(installationID: "test-installation", nectoVersion: "1.0.0")
        let diagnostics = NectoDiagnosticsLog()
        let exporter: NectoInstalledExporter

        init(operations: [NectoOperation] = [], script: String = "") {
            let id = "com.example.exporter-" + UUID().uuidString.lowercased()
            let manifest = NectoPluginManifest(type: .eventExporter, id: id, name: "Exporter fixture",
                description: "Synthetic shutdown test", version: "1.0.0", author: "Example",
                icon: .init(systemName: "testtube.2"), assets: ["index.html"], allowedOrigins: ["self"],
                operations: operations)
            let archive = NectoPanelArchive(files: [.init(path: "index.html", data: Data("""
                <html><script>
                window.events = [];
                window.__nectoExporterReceive = event => window.events.push(event.eventName);
                \(script)
                window.loaded = true;
                </script></html>
                """.utf8))])
            let root = FileManager.default.temporaryDirectory.appending(path: id, directoryHint: .isDirectory)
            let installation = NectoLocalPluginInstallation(pluginID: id, directoryPath: root.path,
                approvedContentHash: archive.contentHash)
            exporter = NectoInstalledExporter(package: .init(manifest: manifest, rootURL: root, source: .installed,
                archive: archive, contentIdentity: archive.contentHash, installation: installation))
        }

        func synchronize(exporter: NectoInstalledExporter?) {
            runtime.synchronize(exporter: exporter, registry: registry, eventDispatcher: dispatcher, diagnostics: diagnostics)
        }

        func open() async throws -> NectoWebPage {
            let principal = try #require(exporter.principal)
            try await registry.install(manifest: exporter.manifest, sourceIdentity: principal.sourceIdentity)
            synchronize(exporter: exporter)
            let page = try #require(runtime.page)
            do {
                try await NectoWebViewSecurityTests.wait(page, for: "window.loaded === true")
                try #require(try await NectoExporterShutdownTests.registerExporter(page))
                return page
            } catch {
                synchronize(exporter: nil)
                throw error
            }
        }
    }

    private static func registerExporter(_ page: NectoWebPage) async throws -> Bool {
        let result = try await page.webView.callAsyncJavaScript(
            "return await window.webkit.messageHandlers.necto.postMessage({type: 'registerExporter'});",
            arguments: [:], in: nil, contentWorld: .page)
        let reply = try #require(result as? [String: Any])
        return try #require(reply["ok"] as? Bool)
    }
}
