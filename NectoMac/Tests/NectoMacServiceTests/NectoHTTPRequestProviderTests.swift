//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import os
import Testing
@testable import NectoMacService

@Suite("Desktop HTTP bridge with stubbed HTTPS transport", .timeLimit(.minutes(1)))
struct NectoHTTPRequestProviderTests {
    private static let pluginID = "http-fixture"
    private static let operationID = "http.request"

    @Test(arguments: ["application/octet-stream", "application/json"])
    func forwardsRequestHeadersAndBody(contentType: String) async throws {
        let body = contentType == "application/json"
            ? Data(#"{"value":"hello"}"#.utf8)
            : Data((0..<32_768).map { UInt8(truncatingIfNeeded: $0) })
        let responseBytes = Data([0, 255, 127, 13, 10])
        let fixture = HTTPSFixture(.reply(201, headers: ["X-Fixture-Response": "hello"], body: responseBytes))
        defer { fixture.stop() }
        let url = fixture.url + "/upload?fixture=1"

        let output = try await invoke([
            "url": .string(url),
            "method": "POST",
            "headers": ["Content-Type": .string(contentType), "Authorization": "Bearer fixture-token"],
            "bodyBase64": .string(body.base64EncodedString()),
        ], provider: fixture.provider)

        let request = try #require(fixture.requests.first)
        #expect(fixture.requests.count == 1)
        #expect(request.url?.absoluteString == url)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == contentType)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.httpBody == body)
        #expect(output["status"] == 201)
        #expect(output["bodyBase64"] == .string(responseBytes.base64EncodedString()))
        let headers = try #require(output["headers"]?.objectValue)
        #expect(headers.first { $0.key.lowercased() == "x-fixture-response" }?.value == "hello")
    }

    @Test(arguments: [404, 503])
    func returnsHTTPErrorResponseWithoutRetry(status: Int) async throws {
        let body = Data("fixture error".utf8)
        let fixture = HTTPSFixture(.reply(status, body: body))
        defer { fixture.stop() }

        let output = try await invoke(["url": .string(fixture.url), "method": "GET"], provider: fixture.provider)

        #expect(output["status"] == .number(Double(status)))
        #expect(output["bodyBase64"] == .string(body.base64EncodedString()))
        #expect(fixture.requests.map(\.httpMethod) == ["GET"])
        #expect(fixture.requests.allSatisfy { $0.httpBody == nil && $0.httpBodyStream == nil })
    }

    @Test func passesExplicitCookiesOnlyForThatInvocation() async throws {
        let setCookie = "received=fixture; Path=/"
        let fixture = HTTPSFixture(.reply(200, headers: ["Set-Cookie": setCookie]))
        defer { fixture.stop() }
        let provider = fixture.provider
        let url = NectoJSONValue.string(fixture.url)

        let output = try await invoke([
            "url": url, "method": "GET", "headers": ["Cookie": "sent=fixture"],
        ], provider: provider)
        let headers = try #require(output["headers"]?.objectValue)
        #expect(headers.first { $0.key.lowercased() == "set-cookie" }?.value == .string(setCookie))

        let next = try await invoke(["url": url, "method": "GET"], provider: provider)
        #expect(next["status"] == 200)
        #expect(fixture.requests.map { $0.value(forHTTPHeaderField: "Cookie") } == ["sent=fixture", nil])
    }

    @Test(arguments: [false, true])
    func followsOnlyHTTPSRedirects(downgrade: Bool) async throws {
        let destination = HTTPSFixture(.reply(200, body: Data("destination".utf8)))
        defer { destination.stop() }
        var location = try #require(URLComponents(string: destination.url))
        if downgrade { location.scheme = "http" }
        let target = try #require(location.url)
        let source = HTTPSFixture(.redirect(target))
        defer { source.stop() }
        let input: NectoJSONValue = ["url": .string(source.url), "method": "GET"]

        if downgrade {
            let error = await #expect(throws: NectoBridgeError.self) { try await invoke(input, provider: source.provider) }
            #expect(error?.code == .providerFailed)
            #expect(destination.requests.isEmpty)
        } else {
            let output = try await invoke(input, provider: source.provider)
            #expect(output["status"] == 200)
            #expect(output["bodyBase64"] == .string(Data("destination".utf8).base64EncodedString()))
            #expect(destination.requests.map(\.url) == [target])
        }
        #expect(source.requests.count == 1)
    }

    @Test(arguments: [
        ["method": "GET"],
        ["url": "relative/path", "method": "GET"],
        ["url": "file:///etc/hosts", "method": "GET"],
        ["url": "http://127.0.0.1:1", "method": "GET"],
        ["url": "https://", "method": "GET"],
        ["url": "https://127.0.0.1:1"],
        ["url": "https://127.0.0.1:1", "method": ""],
        ["url": "https://127.0.0.1:1", "method": "GET /"],
        ["url": "https://127.0.0.1:1", "method": "GET", "headers": "text/plain"],
        ["url": "https://127.0.0.1:1", "method": "GET", "headers": ["X-Fixture": 1]],
        ["url": "https://127.0.0.1:1", "method": "GET", "headers": ["X-Fixture:": "value"]],
        ["url": "https://127.0.0.1:1", "method": "GET", "headers": ["X-Fixture": "value\r\nInjected: value"]],
        ["url": "https://127.0.0.1:1", "method": "POST", "bodyBase64": 42],
        ["url": "https://127.0.0.1:1", "method": "POST", "bodyBase64": "YQ==!"],
    ] as [NectoJSONValue])
    func rejectsInvalidInput(input: NectoJSONValue) async {
        let error = await #expect(throws: NectoBridgeError.self) {
            try await invoke(input, provider: NectoHTTPRequestProvider())
        }
        #expect(error?.code == .invalidInput)
    }

    @Test func reportsSanitizedTransportFailure() async throws {
        let fixture = HTTPSFixture(.fail)
        defer { fixture.stop() }
        let url = fixture.url + "/fixture-private-path"

        let failure = await #expect(throws: NectoBridgeError.self) {
            try await invoke(["url": .string(url), "method": "GET"], provider: fixture.provider)
        }

        let error = try #require(failure)
        #expect(error.code == .providerFailed)
        let serialized = try NectoJSONValue(encoding: error).jsonString()
        #expect(!serialized.contains("fixture-private-path"))
        #expect(!serialized.contains("127.0.0.1"))
        #expect(!serialized.contains("fixture-token"))
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func stopsLoadingWhenInvocationEnds(cancel: Bool) async throws {
        let fixture = HTTPSFixture(.stall)
        defer { fixture.stop() }
        let registry = try await makeRegistry(provider: fixture.provider, timeoutMs: cancel ? 0 : 1_000)
        let pending = Task {
            try await registry.invoke(
                pluginID: Self.pluginID, operationID: Self.operationID,
                input: ["url": .string(fixture.url), "method": "POST"], target: nil
            )
        }
        defer { pending.cancel() }

        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            fixture.events.continuation.finish()
        }
        defer { watchdog.cancel() }
        var events = fixture.events.stream.makeAsyncIterator()
        try #require(await events.next() == .started)
        if cancel { pending.cancel() }
        try #require(await events.next() == .stopped)

        let error = await #expect(throws: NectoBridgeError.self) { try await pending.value }
        if cancel {
            #expect(error?.code != .timeout)
        } else {
            #expect(error?.code == .timeout)
        }
    }

    @Test func cancellingOneRequestLeavesOtherWorkInTheSessionRunning() async throws {
        let cancelled = HTTPSFixture(.stall)
        let survivor = HTTPSFixture(.stall)
        defer { cancelled.stop(); survivor.stop() }
        let registry = try await makeRegistry(provider: cancelled.provider, timeoutMs: 7_000)
        let first = Task {
            try await registry.invoke(
                pluginID: Self.pluginID, operationID: Self.operationID,
                input: ["url": .string(cancelled.url), "method": "GET"], target: nil
            )
        }
        let second = Task {
            try await registry.invoke(
                pluginID: Self.pluginID, operationID: Self.operationID,
                input: ["url": .string(survivor.url), "method": "GET"], target: nil
            )
        }
        defer { first.cancel(); second.cancel() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            cancelled.events.continuation.finish()
            survivor.events.continuation.finish()
        }
        defer { watchdog.cancel() }
        var cancelledEvents = cancelled.events.stream.makeAsyncIterator()
        var survivorEvents = survivor.events.stream.makeAsyncIterator()
        try #require(await cancelledEvents.next() == .started)
        try #require(await survivorEvents.next() == .started)

        first.cancel()
        try #require(await cancelledEvents.next() == .stopped)
        let failure = await #expect(throws: NectoBridgeError.self) { try await first.value }
        #expect(failure?.code != .timeout)

        try #require(survivor.completeStalledRequest())
        let output = try await second.value
        #expect(output["status"] == 200)
    }

    private func invoke(_ input: NectoJSONValue, provider: NectoHTTPRequestProvider) async throws -> NectoJSONValue {
        try await provider.invoke(input: input, context: NectoInvocationContext(
            principal: .init(pluginID: Self.pluginID, sourceIdentity: "fixture"),
            target: nil
        ))
    }

    private func makeRegistry(provider: NectoHTTPRequestProvider, timeoutMs: Int) async throws -> NectoPluginRegistry {
        let registry = NectoPluginRegistry()
        await registry.registerHostProvider(provider)
        try await registry.install(manifest: NectoPluginManifest(
            id: Self.pluginID, name: "HTTP Fixture", description: "HTTP tests", version: "1.0.0", author: "Necto",
            icon: .init(systemName: "network"), assets: ["index.html"], allowedOrigins: ["self"],
            operations: [
                NectoOperation(
                    id: Self.operationID, title: "Request", description: "Send HTTPS request", kind: .once,
                    binding: NectoBridgeBinding(name: "necto.desktop.http.request", version: 1),
                    inputSchema: ["type": "object"], outputSchema: ["type": "object"], timeoutMs: timeoutMs
                ),
            ]
        ), sourceIdentity: "fixture")
        return registry
    }
}

private final class HTTPSFixture: Sendable {
    enum Response: Sendable {
        case reply(_ status: Int, headers: [String: String] = [:], body: Data = Data())
        case redirect(URL)
        case fail
        case stall
    }

    enum Event: Sendable {
        case started
        case stopped
    }

    private static let fixtures = OSAllocatedUnfairLock(initialState: [String: HTTPSFixture]())
    private let id = UUID().uuidString
    private let received = OSAllocatedUnfairLock(initialState: [URLRequest]())
    private let deferredReply = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    let events = AsyncStream<Event>.makeStream()
    let response: Response

    var url: String { "https://127.0.0.1:1/\(id)" }
    var requests: [URLRequest] { received.withLock { $0 } }
    var provider: NectoHTTPRequestProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return NectoHTTPRequestProvider(configuration: configuration)
    }

    init(_ response: Response) {
        self.response = response
        Self.fixtures.withLock { $0[id] = self }
    }

    func stop() {
        Self.fixtures.withLock { $0[id] = nil }
        deferredReply.withLock { $0 = nil }
        events.continuation.finish()
    }

    func record(_ request: URLRequest) {
        var captured = request
        // URL loading can turn the in-memory body into a stream before invoking the protocol.
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 8_192)
            var count = stream.read(&buffer, maxLength: buffer.count)
            while count > 0 {
                body.append(contentsOf: buffer.prefix(count))
                count = stream.read(&buffer, maxLength: buffer.count)
            }
            captured.httpBody = body
        }
        received.withLock { [captured] in $0.append(captured) }
    }

    func stall(reply: @escaping @Sendable () -> Void) {
        deferredReply.withLock { $0 = reply }
        events.continuation.yield(.started)
    }

    func completeStalledRequest() -> Bool {
        let reply = deferredReply.withLock { reply in
            defer { reply = nil }
            return reply
        }
        guard let reply else { return false }
        reply()
        return true
    }

    func loadingStopped() {
        deferredReply.withLock { $0 = nil }
        events.continuation.yield(.stopped)
    }

    static func find(_ request: URLRequest) -> HTTPSFixture? {
        guard let id = request.url?.pathComponents.dropFirst().first else { return nil }
        return fixtures.withLock { $0[id] }
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        HTTPSFixture.find(request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = HTTPSFixture.find(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        fixture.record(request)
        switch fixture.response {
        case let .reply(status, headers, body):
            reply(url: url, status: status, headers: headers, body: body)
        case let .redirect(target):
            reply(url: url, status: 307, headers: ["Location": target.absoluteString], redirect: target)
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted, userInfo: [
                NSURLErrorFailingURLStringErrorKey: url.absoluteString,
                NSLocalizedDescriptionKey: "Fixture TLS failure with fixture-token at \(url)",
            ]))
        case .stall:
            fixture.stall { [self] in reply(url: url, status: 200, headers: [:]) }
        }
    }

    override func stopLoading() {
        HTTPSFixture.find(request)?.loadingStopped()
    }

    private func reply(url: URL, status: Int, headers: [String: String], body: Data = Data(), redirect: URL? = nil) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let redirect {
            var redirectedRequest = request
            redirectedRequest.url = redirect
            client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
        }
        // The original response is delivered if the task delegate refuses the redirect.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
