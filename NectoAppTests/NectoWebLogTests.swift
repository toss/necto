//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel
import Testing
import WebKit

@Suite("Web event logging", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoWebLogTests {
    private func fixture(id: String = "com.example.web-log", version: String = "2.3.4",
                         source: NectoInstalledPackage.Source = .installed,
                         exporter: Bool = false, installed: Bool = true) -> NectoInstalledPackage {
        let manifest = NectoPluginManifest(type: exporter ? .eventExporter : nil,
            id: id, name: "Web log fixture", description: "Synthetic web log test",
            version: version, author: "Example", icon: .init(systemName: "testtube.2"),
            assets: ["index.html"], allowedOrigins: ["self"], operations: [])
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
