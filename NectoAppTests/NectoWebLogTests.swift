//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel
import Testing
import WebKit

private actor WebInvocationContextProbe: NectoOperationProvider {
    nonisolated let descriptor: NectoBridgeDescriptor
    private(set) var channels: [NectoInvocationChannel?] = []

    init(kind: NectoOperationKind) {
        descriptor = .init(binding: .init(name: "necto.desktop.context.\(kind.rawValue)", version: 1), kind: kind)
    }

    func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        channels.append(context.channel)
        return ["ok": true]
    }

    func subscribe(input: NectoJSONValue, context: NectoInvocationContext) async throws
        -> AsyncThrowingStream<NectoJSONValue, any Error> {
        channels.append(context.channel)
        return AsyncThrowingStream { continuation in
            continuation.yield(["ok": true])
            continuation.finish()
        }
    }
}

@Suite("Web event logging", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoWebLogTests {
    private func fixture(id: String = "com.example.web-log", version: String = "2.3.4",
                         source: NectoInstalledPackage.Source = .installed,
                         exporter: Bool = false, installed: Bool = true,
                         operations: [NectoOperation] = []) -> NectoInstalledPackage {
        let manifest = NectoPluginManifest(type: exporter ? .eventExporter : nil,
            id: id, name: "Web log fixture", description: "Synthetic web log test",
            version: version, author: "Example", icon: .init(systemName: "testtube.2"),
            assets: ["index.html"], allowedOrigins: ["self"], operations: operations)
        let archive = NectoPanelArchive(files: [.init(path: "index.html", data: Data("""
        <html><script>
        window.events = [];
        window.__nectoExporterReceive = event => window.events.push(event);
        window.loaded = true;
        </script></html>
        """.utf8))])
        let root = URL(filePath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let installation = installed && source == .installed
            ? NectoLocalPluginInstallation(pluginID: id, directoryPath: root.path,
                                           approvedContentHash: archive.contentHash) : nil
        return NectoInstalledPackage(manifest: manifest, rootURL: root, source: source,
            archive: archive, contentIdentity: archive.contentHash, installation: installation)
    }

    private func open(_ package: NectoInstalledPackage, registry: NectoPluginRegistry,
                      target: NectoTarget? = nil,
                      dispatcher: NectoEventDispatcher? = nil) async throws -> NectoWebPage {
        let page = NectoWebPage(package: package, registry: registry, target: target,
            websiteDataStore: .nonPersistent(), eventDispatcher: dispatcher)
        do {
            try await NectoWebViewSecurityTests.wait(page, for: "window.loaded === true")
            return page
        } catch {
            page.invalidate()
            throw error
        }
    }

    private func install(_ package: NectoInstalledPackage, registry: NectoPluginRegistry,
                         target: NectoTarget? = nil) async throws {
        let principal = try #require(package.principal)
        if case .device = package.source, let target {
            try await registry.installDevice(manifest: package.manifest,
                sourceIdentity: principal.sourceIdentity, for: target)
        } else {
            try await registry.install(manifest: package.manifest, sourceIdentity: principal.sourceIdentity)
        }
    }

    private func request(_ page: NectoWebPage, _ body: String) async throws -> [String: Any] {
        let result = try await page.webView.callAsyncJavaScript(
            "return await window.webkit.messageHandlers.necto.postMessage(\(body));",
            arguments: [:], in: nil, contentWorld: .page)
        return try #require(result as? [String: Any])
    }

    private func expectSuccess(_ page: NectoWebPage, _ body: String) async throws {
        #expect(try await request(page, body)["ok"] as? Bool == true)
    }

    private func expectError(_ page: NectoWebPage, _ body: String, code: String) async throws {
        let response = try await request(page, body)
        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == code)
        #expect((error["message"] as? String)?.isEmpty == false)
    }

    private func receive(_ dispatcher: NectoEventDispatcher,
                         registry: NectoPluginRegistry) async throws -> NectoWebPage {
        let page = try await open(fixture(id: "com.example.receiver", exporter: true),
                                  registry: registry, dispatcher: dispatcher)
        do {
            try await expectSuccess(page, "{type:'registerExporter'}")
            return page
        } catch {
            page.invalidate()
            throw error
        }
    }

    @Test("Web invoke and subscribe establish channel without trusting payload metadata")
    func webInvocationContext() async throws {
        let registry = NectoPluginRegistry()
        let once = WebInvocationContextProbe(kind: .once)
        let stream = WebInvocationContextProbe(kind: .stream)
        let probes = [once, stream]
        for probe in probes { await registry.registerHostProvider(probe) }
        let package = fixture(operations: probes.map { probe in
            NectoOperation(
                id: probe.descriptor.kind.rawValue,
                title: "Context fixture",
                description: "Records host-established invocation context",
                kind: probe.descriptor.kind,
                binding: probe.descriptor.binding,
                inputSchema: [:],
                outputSchema: [:],
                timeoutMs: 1000
            )
        })
        try await install(package, registry: registry)
        let page = try await open(package, registry: registry)
        defer { page.invalidate() }
        try await expectSuccess(page, "{type:'invoke',operationID:'once',channel:'cli',input:{invocationChannel:'cli'}}")
        try await expectSuccess(page, "{type:'subscribe',operationID:'stream',channel:'cli',input:{invocationChannel:'cli'}}")
        #expect(await once.channels == [.web])
        #expect(await stream.channels == [.web])
    }

    @Test("Device and desktop documents use host metadata and the web channel even when hidden")
    func hostMetadataAndHiddenPage() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "synthetic-installation", nectoVersion: "1.2.3",
                                             now: { Date(timeIntervalSince1970: 123) })
        let registry = NectoPluginRegistry(eventDispatcher: dispatcher)
        let receiver = try await receive(dispatcher, registry: registry)
        defer { receiver.invalidate() }
        let target = NectoTarget(deviceID: "synthetic-target", appBundleID: "com.example.connected")
        let desktop = fixture()
        let device = fixture(id: "com.example.device-web-log", version: "4.5.6",
                             source: .device(appName: "Fixture", appBundleID: target.appBundleID))
        try await install(desktop, registry: registry)
        try await install(device, registry: registry, target: target)
        let desktopPage = try await open(desktop, registry: registry, target: target)
        defer { desktopPage.invalidate() }
        let devicePage = try await open(device, registry: registry, target: target)
        defer { devicePage.invalidate() }
        devicePage.setVisible(false, find: nil, scale: 1)
        #expect(devicePage.webView.isHidden && devicePage.webView.window == nil)
        #expect(desktopPage.webView.url?.host != devicePage.webView.url?.host)

        try await expectSuccess(desktopPage, "{type:'log', input:{eventName:'desktop.opened'}}")
        try await expectSuccess(devicePage, """
            {type:'log', pluginID:'forged', sourceIdentity:'forged', target:null, channel:'cli',
             input:{eventName:'device.hidden', params:{pluginId:'custom',origin:'necto',channel:'cli',count:2}}}
            """)
        try await NectoWebViewSecurityTests.wait(receiver, for: "window.events.length === 2")
        let metadata = try await receiver.webView.evaluateJavaScript("""
            window.events[0].origin === 'desktop' && window.events[0].pluginVersion === '2.3.4' &&
            window.events[1].origin === 'device' && window.events[1].pluginVersion === '4.5.6' &&
            window.events[0].pluginId === 'com.example.web-log' &&
            window.events[1].pluginId === 'com.example.device-web-log' &&
            window.events.every(e => e.channel === 'web' &&
                e.installationId === 'synthetic-installation' && e.nectoVersion === '1.2.3' &&
                e.occurredAt === 123000 && typeof e.eventId === 'string') &&
            Object.keys(window.events[0].params).length === 0 &&
            window.events[1].params.pluginId === 'custom' && window.events[1].params.origin === 'necto' &&
            window.events[1].params.channel === 'cli' && window.events[1].params.count === 2
            """) as? Bool
        #expect(metadata == true)
    }

    @Test("Excluded web logs succeed without delivery and resuming never replays them")
    func exclusionsAndResume() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "synthetic", nectoVersion: "1.0.0")
        let registry = NectoPluginRegistry(eventDispatcher: dispatcher)
        let receiver = try await receive(dispatcher, registry: registry)
        defer { receiver.invalidate() }
        let package = fixture()
        try await install(package, registry: registry)
        let sender = try await open(package, registry: registry)
        defer { sender.invalidate() }
        try await expectSuccess(sender, "{type:'log',input:{eventName:'before.exclusion'}}")
        await dispatcher.updatePolicy(.init(excludedPluginIDs: [package.id]))
        try await expectSuccess(sender, "{type:'log',input:{eventName:'excluded'}}")
        await dispatcher.updatePolicy(.init())
        try await expectSuccess(sender, "{type:'log',input:{eventName:'after.resume'}}")
        try await NectoWebViewSecurityTests.wait(receiver, for: "window.events.length >= 2")
        #expect(try await receiver.webView.evaluateJavaScript("window.events.map(e=>e.eventName).join(',')") as? String
                == "before.exclusion,after.resume")
    }

    @Test("No exporter and no dispatcher accept valid logs, validate bad input, and do not replay")
    func missingReceiver() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "synthetic", nectoVersion: "1.0.0")
        let registry = NectoPluginRegistry(eventDispatcher: dispatcher)
        let package = fixture()
        try await install(package, registry: registry)
        let sender = try await open(package, registry: registry)
        defer { sender.invalidate() }
        try await expectSuccess(sender, "{type:'log',input:{eventName:'before.receiver'}}")
        try await expectError(sender, "{type:'log',input:{eventName:''}}", code: "INVALID_INPUT")
        let receiver = try await receive(dispatcher, registry: registry)
        defer { receiver.invalidate() }
        try await expectSuccess(sender, "{type:'log',input:{eventName:'after.receiver'}}")
        try await NectoWebViewSecurityTests.wait(receiver, for: "window.events.length >= 1")
        #expect(try await receiver.webView.evaluateJavaScript("window.events.map(e=>e.eventName).join(',')") as? String
                == "after.receiver")

        let disconnectedRegistry = NectoPluginRegistry()
        try await install(package, registry: disconnectedRegistry)
        let disconnectedPage = try await open(package, registry: disconnectedRegistry)
        defer { disconnectedPage.invalidate() }
        try await expectSuccess(disconnectedPage, "{type:'log',input:{eventName:'without.dispatcher'}}")
        try await expectError(disconnectedPage, "{type:'log',input:{eventName:'bad',params:[]}}", code: "INVALID_INPUT")
    }

    @Test("Bad common input and spoofed event metadata return errors without emitting")
    func rejectsBadInput() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "synthetic", nectoVersion: "1.0.0")
        let registry = NectoPluginRegistry(eventDispatcher: dispatcher)
        let receiver = try await receive(dispatcher, registry: registry)
        defer { receiver.invalidate() }
        let package = fixture()
        try await install(package, registry: registry)
        let sender = try await open(package, registry: registry)
        defer { sender.invalidate() }
        for body in ["{type:'log'}", "{type:'log',input:null}", "{type:'log',input:[]}",
                     "{type:'log',input:{}}", "{type:'log',input:{eventName:1}}",
                     "{type:'log',input:{eventName:'   '}}", "{type:'log',input:{eventName:'bad',params:null}}",
                     "{type:'log',input:{eventName:'bad',params:[]}}"] {
            try await expectError(sender, body, code: "INVALID_INPUT")
        }
        for field in ["eventId", "occurredAt", "installationId", "nectoVersion", "origin", "pluginId",
                      "pluginVersion", "relatedPluginId", "source", "sourceIdentity", "channel", "target"] {
            try await expectError(sender, "{type:'log',input:{eventName:'spoofed',\(field):'forged'}}",
                                  code: "INVALID_INPUT")
        }
        // A delivered sentinel establishes ordering after every rejected request.
        try await expectSuccess(sender, "{type:'log',input:{eventName:'sentinel'}}")
        try await NectoWebViewSecurityTests.wait(receiver, for: "window.events.length >= 1")
        #expect(try await receiver.webView.evaluateJavaScript("window.events.map(e=>e.eventName).join(',')") as? String
                == "sentinel")
    }

    @Test("Removed, replaced and unregistered documents cannot impersonate an installed principal")
    func rejectsStalePrincipals() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "synthetic", nectoVersion: "1.0.0")
        let registry = NectoPluginRegistry(eventDispatcher: dispatcher)
        let receiver = try await receive(dispatcher, registry: registry)
        defer { receiver.invalidate() }
        let original = fixture()
        try await install(original, registry: registry)
        let oldPage = try await open(original, registry: registry)
        defer { oldPage.invalidate() }
        await registry.uninstall(pluginID: original.id)
        try await expectError(oldPage, "{type:'log',input:{eventName:'removed'}}", code: "OPERATION_NOT_FOUND")
        let replacement = fixture(id: original.id, version: "3.0.0")
        try await install(replacement, registry: registry)
        let principal = try #require(replacement.principal)
        let spoofedRequest = """
            {type:'log',pluginID:'\(replacement.id)',sourceIdentity:'\(principal.sourceIdentity)',
             principal:{pluginID:'\(replacement.id)',sourceIdentity:'\(principal.sourceIdentity)'},
             input:{eventName:'stale'}}
            """
        try await expectError(oldPage, spoofedRequest, code: "PERMISSION_DENIED")
        let preview = try await open(fixture(id: original.id, installed: false), registry: registry)
        defer { preview.invalidate() }
        try await expectError(preview, spoofedRequest, code: "OPERATION_UNAVAILABLE")
        let currentPage = try await open(replacement, registry: registry)
        defer { currentPage.invalidate() }
        try await expectSuccess(currentPage, "{type:'log',input:{eventName:'current'}}")
        try await NectoWebViewSecurityTests.wait(receiver, for: "window.events.length >= 1")
        #expect(try await receiver.webView.evaluateJavaScript("window.events.map(e=>e.eventName).join(',')") as? String
                == "current")
    }
}

@Suite("Built-in panel usage logging", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoBuiltInUsageLogTests {
    // Use the shipped HTML and module scripts, with no connected app or system clipboard.
    private func open(_ panel: String, replies: [String: NectoJSONValue]) async throws -> WKWebView {
        let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/\(panel)")
        let archive = try NectoPanelArchive.read(directory: directory)
        let origin = "panel-test"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(NectoPluginSchemeHandler(originHost: origin, archive: archive),
            forURLScheme: NectoPluginSchemeHandler.scheme)
        let fixtures = try NectoJSONValue.object(replies).jsonString()
        configuration.userContentController.addUserScript(NectoBridgeCoordinator.localeUserScript("en"))
        configuration.userContentController.addUserScript(WKUserScript(source: """
            (() => {
              const replies = \(fixtures);
              const host = window.panelTest = { logs: [], writes: [], clipboardSucceeds: true, ready: false };
              const ok = value => ({ok: true, value});
              const postMessage = async message => {
                switch (message.type) {
                  case 'context': return ok({target: {targetHandle: 'fixture'}, operations: []});
                  case 'ready': host.ready = true; return ok(null);
                  case 'subscribe': return ok(message.operationID);
                  case 'log': host.logs.push(message); return ok(null);
                  case 'invoke': {
                    if (host.hold === message.operationID) {
                      await new Promise(resolve => { host.release = resolve; });
                    }
                    const key = message.input?.recordID ?? message.operationID;
                    if (Object.hasOwn(replies, key)) return ok(replies[key]);
                    break;
                  }
                }
                throw new Error(`Unexpected host call: ${JSON.stringify(message)}`);
              };
              Object.defineProperty(window, 'webkit', {value: {messageHandlers: {necto: {postMessage}}}});
              Object.defineProperty(navigator, 'clipboard', {value: {writeText: async text => {
                host.writes.push(text);
                if (!host.clipboardSucceeds) throw new Error('Clipboard denied');
              }}});
              document.execCommand = () => false;
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        let url = try #require(NectoPluginSchemeHandler.entryPointURL(originHost: origin))
        view.load(URLRequest(url: url))
        try await wait(view, for: "window.panelTest?.ready === true")
        return view
    }

    private func wait(_ view: WKWebView, for expression: String) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if (try? await view.evaluateJavaScript(expression) as? Bool) == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(Bool(false), "Panel did not reach: \(expression)")
    }

    private func run(_ view: WKWebView, _ actions: String, arguments: [String: Any] = [:]) async throws {
        _ = try await view.callAsyncJavaScript("""
            const host = window.panelTest;
            const click = selector => document.querySelector(selector).click();
            \(actions)
            """, arguments: arguments, in: nil, contentWorld: .page)
    }

    private func log(_ name: String, _ params: [String: NectoJSONValue] = [:]) -> NectoJSONValue {
        ["type": "log", "input": ["eventName": .string(name), "params": .object(params)]]
    }

    private func expectLogs(_ view: WKWebView, _ expected: [NectoJSONValue]) async throws {
        let result = try await view.evaluateJavaScript("JSON.stringify(window.panelTest.logs)") as? String
        let json = try #require(result)
        let actual = try JSONDecoder().decode([NectoJSONValue].self, from: Data(json.utf8))
        #expect(actual == expected)
    }

    private func copy(_ view: WKWebView, button: String, text: String, succeeds: Bool = true) async throws {
        try await run(view, """
            host.clipboardSucceeds = succeeds;
            host.lastCopy = \(button);
            host.lastCopy.click();
            """, arguments: ["succeeds": succeeds])
        let status = succeeds ? "copied" : "failed"
        try await wait(view, for: "window.panelTest.lastCopy.textContent.toLowerCase() === '\(status)'")
        let actual = try await view.evaluateJavaScript("window.panelTest.writes.at(-1)") as? String
        #expect(actual == text)
    }

    @Test("Network logs changed detail tabs and successful copies of real content only")
    func network() async throws {
        let requestBody: NectoJSONValue = ["text": "synthetic request", "byteCount": 17, "isTruncated": false]
        let responseBody: NectoJSONValue = ["text": "synthetic response", "byteCount": 18, "isTruncated": false]
        let curl = "curl https://example.invalid/request"
        let row: [String: NectoJSONValue] = [
            "id": "with-curl", "method": "POST", "url": "https://example.invalid/request", "name": "with-curl",
            "host": "example.invalid", "state": "completed", "startedAtMilliseconds": 2, "statusCode": 200,
        ]
        var noCurl = row
        noCurl["id"] = "without-curl"
        noCurl["name"] = "without-curl"
        noCurl["startedAtMilliseconds"] = 1
        let detail = row.merging(["requestBody": requestBody, "responseBody": responseBody, "curl": .string(curl)]) { _, new in new }
        let view = try await open("NectoNetworkPlugin/Panels/network-logger", replies: [
            "records.list": ["records": .array([.object(row), .object(noCurl)])],
            "with-curl": ["record": .object(detail)], "without-curl": ["record": .object(noCurl)],
        ])
        try await run(view, """
            click('tbody tr:first-child');
            click('.necto-tab[aria-selected="true"]');
            click('.necto-tab:nth-child(2)');
            click('.necto-tab[aria-selected="true"]');
            """)
        let button = "document.querySelector('.necto-code-copy')"
        try await wait(view, for: "\(button) !== null")
        try await copy(view, button: button, text: "synthetic request", succeeds: false)
        try await copy(view, button: button, text: "synthetic request")
        try await run(view, "click('.necto-tab:nth-child(3)');")
        try await copy(view, button: button, text: "synthetic response")
        try await run(view, "click('.necto-tab:nth-child(4)');")
        try await copy(view, button: button, text: curl)
        try await run(view, "click('tbody tr:last-child');")
        try await wait(view, for: "document.querySelector('.necto-code')?.textContent === 'No command available.'")
        try await copy(view, button: button, text: "No command available.")
        try await run(view, "click('.necto-tab:first-child');")
        try await expectLogs(view, [
            log("network.detail_tab_changed", ["tab": "request"]), log("network.copied", ["kind": "request_body"]),
            log("network.detail_tab_changed", ["tab": "response"]), log("network.copied", ["kind": "response_body"]),
            log("network.detail_tab_changed", ["tab": "curl"]), log("network.copied", ["kind": "curl"]),
            log("network.detail_tab_changed", ["tab": "summary"]),
        ])
    }

    @Test("Events log filter transitions without search text or selected values")
    func events() async throws {
        let row: NectoJSONValue = ["id": "one", "at": 1, "level": "info", "tag": "example-a",
                                  "message": "synthetic event", "hasDetail": false]
        let view = try await open("NectoEventsPlugin/Panels/event-log", replies: ["events.list": ["events": [row]]])
        try await run(view, """
            window.__nectoBridgeDeliver('events.observe', {event: {
              id: 'two', at: 2, level: 'warn', tag: 'example-b', message: 'synthetic live event', hasDetail: false
            }});
            const change = (id, values, type) => {
              const field = document.getElementById(id);
              for (const value of values) {
                field.value = value;
                field.dispatchEvent(new Event(type, {bubbles: true}));
              }
            };
            change('search', ['  ', 's', 'synthetic query', '  ', ''], 'input');
            change('level', ['', 'info', 'info', 'warn', '', ''], 'change');
            change('category', ['', 'example-a', 'example-a', 'example-b', '', ''], 'change');
            """)
        func filter(_ name: String, _ enabled: Bool) -> NectoJSONValue {
            log("events.filter_changed", ["filter": .string(name), "enabled": .bool(enabled)])
        }
        try await expectLogs(view, [filter("search", true), filter("search", false),
            filter("level", true), filter("level", true), filter("level", false),
            filter("category", true), filter("category", true), filter("category", false)])
    }

    @Test("Files and Preferences log successful copies with no path, key, or value", arguments: ["files", "preferences"])
    func fileAndPreferenceCopies(panel: String) async throws {
        let view: WKWebView
        let label: String
        let text: String
        let event: String
        if panel == "files" {
            let item: NectoJSONValue = ["name": "fixture.txt", "isDirectory": false, "size": 7]
            view = try await open("NectoFilesPlugin/Panels/files", replies: [
                "files.roots": ["roots": [["id": "documents", "name": "Documents", "path": "/fixture"]]],
                "files.list": ["entries": [item]], "files.info": ["item": item],
                "files.preview": ["file": ["name": "fixture.txt", "kind": "text", "size": 7, "text": "example"]],
            ])
            try await run(view, "click('.necto-tree-row');")
            label = "Copy path"
            text = "/fixture/fixture.txt"
            event = "files.path_copied"
        } else {
            view = try await open("NectoPreferencesPlugin/Panels/preferences", replies: [
                "preferences.suites": ["suites": ["standard"]],
                "preferences.list": ["entries": [["key": "example-key", "type": "String",
                                                  "preview": "synthetic value", "isTruncated": false]]],
                "preferences.detail": ["entry": ["key": "example-key", "type": "String", "value": "synthetic value"]],
            ])
            try await run(view, "click('tbody tr');")
            label = "Copy"
            text = "synthetic value"
            event = "preferences.value_copied"
        }
        let button = "[...document.querySelectorAll('.necto-detail button')].find(b => b.textContent === '\(label)')"
        try await wait(view, for: "\(button) !== undefined")
        try await copy(view, button: button, text: text, succeeds: false)
        try await expectLogs(view, [])
        try await copy(view, button: "host.lastCopy", text: text)
        try await expectLogs(view, [log(event)])
    }

    @Test("Performance logs changed windows without startup, repeated selections, or live samples")
    func performance() async throws {
        let view = try await open("NectoPerformancePlugin/Panels/performance-monitor", replies: [
            "performance.metrics": ["metrics": [["id": "cpu", "title": "CPU", "unit": "%"]]],
            "performance.snapshot": [:], "performance.series": ["series": []],
        ])
        try await run(view, """
            window.__nectoBridgeDeliver('performance.observe', {
              metricID: 'cpu', sample: {at: Date.now(), value: 7}, isOverBudget: false
            });
            for (const seconds of [300, 60, 60, 3600, 3600, 300]) click(`[data-window="${seconds}"]`);
            """)
        try await expectLogs(view, [log("performance.window_changed", ["window": "1m"]),
            log("performance.window_changed", ["window": "1h"]), log("performance.window_changed", ["window": "5m"])])
    }

    @Test("Control logs allowed mode changes and ignores blocked and repeated selections")
    func control() async throws {
        let view = try await open("NectoUIControlPlugin/Panels/control", replies: [
            "control.actionTargets": ["targets": []], "control.readAccessibility": ["items": []],
        ])
        try await run(view, """
            click('#actions-tab');
            host.hold = 'control.readAccessibility';
            click('#reading-tab');
            if (!host.release) throw new Error('Reading did not start');
            // Dispatch directly to exercise the panel guard even though the tab is disabled.
            document.querySelector('#actions-tab').dispatchEvent(new MouseEvent('click', {bubbles: true}));
            if (document.querySelector('#reading-tab').getAttribute('aria-selected') !== 'true') {
              throw new Error('The mode changed while loading');
            }
            host.release();
            """)
        try await wait(view, for: "document.querySelector('#control-content').getAttribute('aria-busy') === 'false'")
        try await run(view, "click('#reading-tab'); click('#actions-tab');")
        try await wait(view, for: "document.querySelector('#control-content').getAttribute('aria-busy') === 'false'")
        try await expectLogs(view, [log("control.mode_changed", ["mode": "reading"]),
            log("control.mode_changed", ["mode": "actions"])])
    }
}
