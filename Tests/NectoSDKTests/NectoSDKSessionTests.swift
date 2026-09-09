//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import NectoTransport
import Testing
@testable import NectoSDK

private struct SessionPlugin: NectoPluginable {
    let id = "com.example.session-tests"
    let started: AsyncStream<String>.Continuation
    let cancelled: AsyncStream<String>.Continuation

    func register(_ necto: NectoHandler) {
        necto.handle("session.echo") { input in input }
        necto.handle("session.wait") { input in
            let id = input["id"]?.stringValue ?? ""
            started.yield(id)
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.yield(id) }
            // A plugin may catch cancellation and still return. The SDK must discard this.
            return ["oldResult": .string(id)]
        }
        necto.handle("session.observe") { input, out in
            let id = input["id"]?.stringValue ?? ""
            started.yield(id)
            await out.send(["event": 1])
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.yield(id) }
            await out.send(["lateEvent": 2])
        }
    }
}

private struct CatalogPlugin: NectoPluginable {
    let id = "com.example.catalog"
    let version: Int

    func register(_ necto: NectoHandler) {
        necto.handle("catalog.echo", version: version) { $0 }
    }
}

private final class CatalogWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private let release = AsyncStream<Void>.makeStream()

    func pause() { lock.withLock { paused = true } }
    func close() { release.continuation.finish() }
    func wait() async throws {
        if lock.withLock({ paused }) {
            for await _ in release.stream {}
            try Task.checkCancellation()
        }
    }
}

private struct GatedCatalogStream: NectoByteStream {
    let base: NectoSocketStream
    let gate: CatalogWriteGate
    func read(count: Int) async throws -> Data { try await base.read(count: count) }
    func write(_ data: Data) async throws {
        try await gate.wait()
        try await base.write(data)
    }
    func close() { gate.close(); base.close() }
}

private struct SessionHarness: Sendable {
    let runtime = NectoSDKRuntime()
    let started = AsyncStream<String>.makeStream()
    let cancelled = AsyncStream<String>.makeStream()

    init() {
        #expect(runtime.register(SessionPlugin(started: started.continuation, cancelled: cancelled.continuation)))
    }

    func connect(gate: CatalogWriteGate? = nil, beforeAcknowledgement: (@Sendable () -> Void)? = nil) async throws -> (host: NectoMessageSession, worker: Task<Void, Never>) {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let appStream = NectoSocketStream(descriptor: descriptors[0])
        let transport: any NectoByteStream
        if let gate { transport = GatedCatalogStream(base: appStream, gate: gate) }
        else { transport = appStream }
        let app = NectoMessageSession(stream: transport)
        let host = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[1]))
        let worker = Task { await runtime.accept(session: app) }
        do {
            try await host.handshake(timeout: .seconds(3)) {
                let hello = try await host.receive(NectoHandshakeHello.self)
                #expect(hello.protocolVersion == NectoProtocol.currentVersion)
                beforeAcknowledgement?()
                // SwiftPM's test runner has no app bundle identity; this test host accepts it.
                try await host.send(NectoHandshakeAck(accepted: true))
                let envelope = try await host.receive(NectoEnvelope.self)
                #expect(envelope.type == .pluginRegister)
                let registration = try envelope.decode(NectoPluginRegistration.self)
                #expect(registration.pluginID == "com.example.session-tests")
                #expect(registration.catalog.bridges.count == 3)
            }
            return (host, worker)
        } catch {
            host.close()
            worker.cancel()
            await worker.value
            throw error
        }
    }
}

private func invoke(_ host: NectoMessageSession, id: String, name: String, kind: NectoOperationKind = .once) async throws {
    try await host.send(NectoEnvelope(type: .pluginInvoke, encoding: NectoPluginInvocation(
        requestID: id, name: "necto.device.session." + name, version: 1, kind: kind, input: ["id": .string(id)]
    )))
}

private func result(_ host: NectoMessageSession) async throws -> NectoPluginResult {
    let envelope = try await host.receive(NectoEnvelope.self)
    #expect(envelope.type == .pluginResult)
    return try envelope.decode(NectoPluginResult.self)
}

@Suite("SDK session ownership", .timeLimit(.minutes(1)))
struct NectoSDKSessionTests {
    @Test("catalog overflow closes a stalled session and reconnect restores the latest snapshot")
    func stalledCatalog() async throws {
        let harness = SessionHarness()
        let gate = CatalogWriteGate()
        let first = try await harness.connect(gate: gate)
        defer { first.host.close(); harness.runtime.stop(); first.worker.cancel() }
        gate.pause()
        for version in 1...80 {
            #expect(harness.runtime.register(CatalogPlugin(version: version)))
            harness.runtime.unregister(id: "com.example.catalog")
        }
        #expect(harness.runtime.register(CatalogPlugin(version: 81)))
        _ = try await first.host.handshake(timeout: .seconds(3)) {
            await #expect(throws: NectoSocketStream.Failure.self) {
                _ = try await first.host.receive(NectoEnvelope.self)
            }
        }
        await first.worker.value

        let second = try await harness.connect()
        defer { second.host.close(); second.worker.cancel() }
        try await second.host.handshake(timeout: .seconds(3)) {
            let registration = try await second.host.receive(NectoEnvelope.self).decode(NectoPluginRegistration.self)
            #expect(registration.pluginID == "com.example.catalog")
            #expect(registration.catalog.bridges.map(\.version) == [81])
        }
        second.host.close()
        await second.worker.value
    }

    @Test("dynamic catalog changes preserve mutation order and each version", arguments: 0..<10)
    func orderedCatalog(_: Int) async throws {
        let harness = SessionHarness()
        let (host, worker) = try await harness.connect()
        defer { host.close(); harness.runtime.stop(); worker.cancel() }
        for version in 1...20 {
            #expect(harness.runtime.register(CatalogPlugin(version: version)))
            harness.runtime.unregister(id: "com.example.catalog")
        }
        try await host.handshake(timeout: .seconds(3)) {
            for version in 1...20 {
                let added = try await host.receive(NectoEnvelope.self).decode(NectoPluginRegistration.self)
                #expect(added.pluginID == "com.example.catalog")
                #expect(added.catalog.bridges.map(\.version) == [version])
                let removed = try await host.receive(NectoEnvelope.self).decode(NectoPluginRegistration.self)
                #expect(removed.pluginID == "com.example.catalog")
                #expect(removed.catalog.bridges.isEmpty)
            }
        }
        host.close()
        await worker.value
    }

    @Test("mutations during handshake appear only in the accepted session snapshot", arguments: 0..<10)
    func catalogDuringHandshake(_: Int) async throws {
        let harness = SessionHarness()
        let (host, worker) = try await harness.connect {
            #expect(harness.runtime.register(CatalogPlugin(version: 1)))
            harness.runtime.unregister(id: "com.example.catalog")
            #expect(harness.runtime.register(CatalogPlugin(version: 2)))
        }
        defer { host.close(); harness.runtime.stop(); worker.cancel() }
        try await host.handshake(timeout: .seconds(3)) {
            let registration = try await host.receive(NectoEnvelope.self).decode(NectoPluginRegistration.self)
            #expect(registration.pluginID == "com.example.catalog")
            #expect(registration.catalog.bridges.map(\.version) == [2])
            try await invoke(host, id: "after-catalog", name: "echo")
            #expect(try await result(host).requestID == "after-catalog")
        }
        host.close()
        await worker.value
    }

    @Test("existing registration and once-handler contracts work over a socket")
    func pluginContract() async throws {
        let harness = SessionHarness()
        let (host, worker) = try await harness.connect()
        defer { host.close(); harness.runtime.stop(); worker.cancel() }
        try await host.handshake(timeout: .seconds(3)) {
            try await invoke(host, id: "echo", name: "echo")
            let reply = try await result(host)
            #expect(reply.requestID == "echo")
            #expect(reply.output == ["id": "echo"])
            #expect(reply.isFinal)
        }
        host.close()
        await worker.value
    }

    @Test("invoke followed immediately by cancel cannot leave a live request", arguments: 0..<20)
    func immediateCancel(_: Int) async throws {
        let harness = SessionHarness()
        let (host, worker) = try await harness.connect()
        defer { host.close(); harness.runtime.stop(); worker.cancel() }
        try await host.handshake(timeout: .seconds(3)) {
            try await invoke(host, id: "cancelled", name: "wait")
            try await host.send(NectoEnvelope(type: .pluginCancel, encoding: NectoPluginCancel(requestID: "cancelled")))
            try await invoke(host, id: "echo", name: "echo")
            let reply = try await result(host)
            #expect(reply.requestID == "echo")
        }
        host.close()
        await worker.value
    }

    @Test("disconnect cancels a stream and drops output after cancellation")
    func disconnectStream() async throws {
        let harness = SessionHarness()
        let (host, worker) = try await harness.connect()
        defer { host.close(); harness.runtime.stop(); worker.cancel() }
        try await invoke(host, id: "stream", name: "observe", kind: .stream)
        let event = try await result(host)
        #expect(event.output == ["event": 1])
        #expect(!event.isFinal)
        host.close()
        var iterator = harness.cancelled.stream.makeAsyncIterator()
        #expect(await iterator.next() == "stream")
        await worker.value
    }

    @Test("replacement session cancels old work without routing old replies to the new host")
    func replaceSession() async throws {
        let harness = SessionHarness()
        let first = try await harness.connect()
        defer { first.host.close(); first.worker.cancel(); harness.runtime.stop() }
        try await invoke(first.host, id: "same-id", name: "wait")
        var started = harness.started.stream.makeAsyncIterator()
        #expect(await started.next() == "same-id")

        let second = try await harness.connect()
        defer { second.host.close(); second.worker.cancel() }
        var cancelled = harness.cancelled.stream.makeAsyncIterator()
        #expect(await cancelled.next() == "same-id")
        await first.worker.value
        try await second.host.handshake(timeout: .seconds(3)) {
            try await invoke(second.host, id: "same-id", name: "echo")
            let reply = try await result(second.host)
            #expect(reply.output == ["id": "same-id"])
            #expect(reply.error == nil)
        }
        second.host.close()
        await second.worker.value
    }

    @Test("stop cancels active handlers and retains registered plugins for a new session")
    func stopAndReconnect() async throws {
        let harness = SessionHarness()
        let first = try await harness.connect()
        defer { first.host.close(); first.worker.cancel(); harness.runtime.stop() }
        try await invoke(first.host, id: "stopped", name: "wait")
        var started = harness.started.stream.makeAsyncIterator()
        #expect(await started.next() == "stopped")
        harness.runtime.stop()
        var cancelled = harness.cancelled.stream.makeAsyncIterator()
        #expect(await cancelled.next() == "stopped")
        await first.worker.value
        #expect(harness.runtime.status == .stopped)

        let second = try await harness.connect()
        defer { second.host.close(); second.worker.cancel() }
        try await invoke(second.host, id: "new", name: "echo")
        #expect(try await result(second.host).output == ["id": "new"])
        second.host.close()
        await second.worker.value
    }
}
