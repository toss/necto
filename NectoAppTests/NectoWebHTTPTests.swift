//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
@testable import NectoMacService
import NectoModel
import os
import Testing
import WebKit

@Suite("Web HTTP bridge", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NectoWebHTTPTests {
    @Test("A hidden exporter sends JSON bytes and receives a mocked HTTPS error response")
    func hiddenExporterRequest() async throws {
        let requestBody = Data(#"{"event":"example","message":"café"}"#.utf8)
        let responseBody = Data([0x00, 0xff, 0x0a])
        let fixture = WebHTTPSFixture(responseBody: responseBody)
        defer { fixture.remove() }
        let page = try await openExporter()
        defer { page.invalidate() }
        #expect(page.webView.isHidden && page.webView.window == nil)

        // The native suite runs without a JavaScript package build. Send the
        // same WebKit message that necto.desktop.send posts for this operation.
        let result = try await page.webView.callAsyncJavaScript("""
            return await window.webkit.messageHandlers.necto.postMessage({
                type: 'invoke', operationID: 'deliver',
                input: {url, method: 'POST', headers: {
                    'Authorization': 'Bearer synthetic-fixture',
                    'Content-Type': 'application/json'
                }, bodyBase64}
            });
            """, arguments: ["url": fixture.url.absoluteString, "bodyBase64": requestBody.base64EncodedString()],
            in: nil, contentWorld: .page)

        let request = try #require(fixture.request)
        #expect(request.url == fixture.url)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer synthetic-fixture")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.httpBody == requestBody)

        let reply = try #require(result as? [String: Any])
        try #require(reply["ok"] as? Bool == true, "Expected a successful bridge reply: \(reply)")
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["status"] as? Int == 422)
        let headers = try #require(value["headers"] as? [String: String])
        #expect(headers.first { $0.key.lowercased() == "x-example-result" }?.value == "fixture")
        #expect(value["bodyBase64"] as? String == responseBody.base64EncodedString())
    }

    @Test("Invalidating a hidden exporter stops its stalled HTTPS fixture request")
    func cancellation() async throws {
        let fixture = WebHTTPSFixture(responseBody: nil)
        defer { fixture.remove() }
        let page = try await openExporter()
        defer { page.invalidate() }

        _ = try await page.webView.callAsyncJavaScript("""
            void window.webkit.messageHandlers.necto.postMessage({
                type: 'invoke', operationID: 'deliver', input: {url, method: 'GET'}
            }).catch(() => {});
            """, arguments: ["url": fixture.url.absoluteString], in: nil, contentWorld: .page)
        try await wait("stalled request") { fixture.request != nil }
        #expect(fixture.request?.httpMethod == "GET")
        try #require(!fixture.stopped)

        page.invalidate()
        // The operation deadline is much later. Only page teardown should
        // terminate the parked request within this observation window.
        try await wait("URLProtocol.stopLoading") { fixture.stopped }
    }

    private struct ObservationTimedOut: Error {
        let observation: String
    }

    private func wait(_ observation: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ObservationTimedOut(observation: observation) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func openExporter() async throws -> NectoWebPage {
        let registry = NectoPluginRegistry()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebHTTPSProtocol.self]
        await registry.registerHostProvider(NectoHTTPRequestProvider(configuration: configuration))
        let operation = NectoOperation(id: "deliver", title: "Deliver", description: "Send a synthetic event",
            kind: .once, binding: .init(name: "necto.desktop.http.request", version: 1),
            inputSchema: [
                "type": "object", "required": ["url", "method"],
                "properties": [
                    "url": ["type": "string"], "method": ["type": "string"],
                    "headers": ["type": "object"], "bodyBase64": ["type": "string"],
                ],
            ],
            outputSchema: [
                "type": "object", "required": ["status", "headers", "bodyBase64"],
                "properties": ["status": ["type": "number"], "headers": ["type": "object"],
                               "bodyBase64": ["type": "string"]],
            ], timeoutMs: 30_000)
        let manifest = NectoPluginManifest(type: .eventExporter, id: "com.example.web-http",
            name: "HTTP exporter fixture", description: "Synthetic exporter", version: "1.0.0",
            author: "Example", icon: .init(systemName: "testtube.2"), assets: ["index.html"],
            allowedOrigins: ["self"], operations: [operation])
        let archive = NectoPanelArchive(files: [.init(path: "index.html",
            data: Data("<html><script>window.loaded = true;</script></html>".utf8))])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installation = NectoLocalPluginInstallation(pluginID: manifest.id, directoryPath: root.path,
            approvedContentHash: archive.contentHash)
        let package = NectoInstalledPackage(manifest: manifest, rootURL: root, source: .installed,
            archive: archive, contentIdentity: archive.contentHash, installation: installation)
        let principal = try #require(package.principal)
        try await registry.install(manifest: manifest, sourceIdentity: principal.sourceIdentity)

        let page = NectoWebPage(package: package, registry: registry, target: nil, websiteDataStore: .nonPersistent())
        page.setVisible(false, find: nil, scale: 1)
        do {
            try await NectoWebViewSecurityTests.wait(page, for: "window.loaded === true")
            return page
        } catch {
            page.invalidate()
            throw error
        }
    }
}

/// Routes test-only URLSession loads by a unique URL for each fixture.
private final class WebHTTPSFixture: Sendable {
    private struct State: Sendable {
        var request: URLRequest?
        var stopped = false
    }

    private static let fixtures = OSAllocatedUnfairLock(initialState: [URL: WebHTTPSFixture]())
    private let state = OSAllocatedUnfairLock(initialState: State())
    let url = URL(string: "https://example.invalid/events/\(UUID().uuidString)")!
    let responseBody: Data?

    init(responseBody: Data?) {
        self.responseBody = responseBody
        Self.fixtures.withLock { $0[url] = self }
    }

    static func matching(_ request: URLRequest) -> WebHTTPSFixture? {
        guard let url = request.url else { return nil }
        return fixtures.withLock { $0[url] }
    }

    var request: URLRequest? { state.withLock { $0.request } }
    var stopped: Bool { state.withLock { $0.stopped } }

    func record(_ request: URLRequest) { state.withLock { $0.request = request } }
    func recordStop() { state.withLock { $0.stopped = true } }

    func remove() {
        _ = Self.fixtures.withLock { $0.removeValue(forKey: url) }
    }
}

private final class WebHTTPSProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = WebHTTPSFixture.matching(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var captured = request
        // URLSession can turn URLRequest.httpBody into a stream before interception.
        if let stream = request.httpBodyStream {
            captured.httpBody = Self.readBody(stream)
        }
        fixture.record(captured)
        // Leave a stalled fixture pending until URLSession cancels it.
        guard let body = fixture.responseBody else { return }
        guard let response = HTTPURLResponse(url: fixture.url, statusCode: 422, httpVersion: "HTTP/1.1",
            headerFields: ["X-Example-Result": "fixture"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        WebHTTPSFixture.matching(request)?.recordStop()
    }

    private static func readBody(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            if count < 0 { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
