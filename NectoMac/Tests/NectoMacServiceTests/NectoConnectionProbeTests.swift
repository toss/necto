//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import NectoSDK
import NectoTransport
import Testing

@testable import NectoMacService

// Nearby ephemeral ports can share a probe range, so these listeners must not overlap.
@Suite("Independent connection probes", .serialized, .timeLimit(.minutes(1)))
struct NectoConnectionProbeTests {
    private actor Peer {
        let listener: NectoDeviceListener
        let sendsHello: Bool
        private var sessions: [NectoMessageSession] = []
        private var task: Task<Void, Never>?

        init(listener: NectoDeviceListener, sendsHello: Bool) {
            self.listener = listener
            self.sendsHello = sendsHello
        }

        var count: Int { sessions.count }

        func start() {
            task = Task {
                do {
                    for try await session in listener.sessions() {
                        if sendsHello { try await hello(session) }
                        sessions.append(session)
                    }
                } catch {
                    if !Task.isCancelled { Issue.record(error) }
                }
            }
        }

        func hello(_ session: NectoMessageSession) async throws {
            try await session.handshake(timeout: .seconds(3)) {
                try await session.send(NectoHandshakeHello(
                    appBundleID: "com.example.probe.\(self.listener.port)",
                    appName: "Probe test", appVersion: "1.0.0",
                    deviceName: "Test simulator", sdkVersion: "0.4.2",
                    simulatorID: "probe-simulator"
                ))
                #expect(try await session.receive(NectoHandshakeAck.self).accepted)
            }
        }

        func session(at index: Int) throws -> NectoMessageSession {
            try #require(sessions.indices.contains(index))
            return sessions[index]
        }

        func stop() async {
            task?.cancel()
            listener.stop()
            for session in sessions { session.close() }
            await task?.value
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, "Connection state did not converge within three seconds")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func listeners() throws -> (NectoDeviceListener, NectoDeviceListener) {
        for _ in 0..<20 {
            let first = NectoDeviceListener(port: 0)
            try first.start()
            for port in NectoConnectionCenter.portsToDial(from: first.port, skipping: [first.port]) {
                let second = NectoDeviceListener(port: port)
                if (try? second.start()) != nil { return (first, second) }
            }
            first.stop()
        }
        throw NectoDeviceListener.Failure.cannotListen("Could not reserve two ports in one probe range")
    }

    private func withPeers(_ body: (NectoConnectionCenter, Peer, Peer) async throws -> Void) async throws {
        let (silentListener, listener) = try listeners()
        defer { silentListener.stop(); listener.stop() }
        let silent = Peer(listener: silentListener, sendsHello: false)
        let responding = Peer(listener: listener, sendsHello: true)
        let center = NectoConnectionCenter(
            port: silentListener.port, probeInterval: .milliseconds(50),
            // TCP fixtures must not probe devices attached to the developer's Mac.
            deviceEvents: { AsyncThrowingStream { $0.finish() } }
        )
        await silent.start()
        await responding.start()
        await center.start()
        do {
            // The host publishes its connection before the peer has necessarily read the ack.
            try await waitUntil { await responding.count == 1 }
            try await body(center, silent, responding)
        } catch {
            await center.stop()
            await silent.stop()
            await responding.stop()
            throw error
        }
        await center.stop()
        await silent.stop()
        await responding.stop()
    }

    @Test("a silent port cannot delay another port's connection or reconnection")
    func silentPortDoesNotBlock() async throws {
        try await withPeers { center, silent, responding in
            try await waitUntil { await silent.count == 1 }
            try await waitUntil { await center.connectedApps.count == 1 }
            let first = try await responding.session(at: 0)
            first.close()
            try await waitUntil { await responding.count == 2 }
            try await waitUntil { await center.connectedApps.count == 1 }
            #expect(await silent.count == 1)
        }
    }

    @Test("repeated start and retry ticks do not duplicate pending or connected probes")
    func noDuplicateProbes() async throws {
        try await withPeers { center, silent, responding in
            try await waitUntil { await silent.count == 1 }
            try await waitUntil { await center.connectedApps.count == 1 }
            for _ in 0..<5 {
                await center.start()
                try await Task.sleep(for: .milliseconds(60))
            }
            #expect(await silent.count == 1)
            #expect(await responding.count == 1)
            await center.stop()
            let pending = try await silent.session(at: 0)
            await #expect(throws: NectoSocketStream.Failure.self) {
                try await pending.handshake(timeout: .seconds(3)) {
                    try await pending.receive(NectoHandshakeAck.self)
                }
            }
            #expect(await center.connectedApps.isEmpty)
        }
    }

    @Test("a stopped app can resume listening while another port is still silent")
    func listenerRestarts() async throws {
        try await withPeers { center, silent, responding in
            try await waitUntil { await center.connectedApps.count == 1 }
            await responding.stop()
            try await waitUntil { await center.connectedApps.isEmpty }
            try await Task.sleep(for: .milliseconds(200))
            try responding.listener.start()
            await responding.start()
            try await waitUntil { await responding.count == 2 }
            try await waitUntil { await center.connectedApps.count == 1 }
            #expect(await silent.count == 1)
        }
    }

    @Test("stop then immediate restart cancels old probes without cancelling replacements", arguments: 0..<5)
    func restartProbes(_: Int) async throws {
        try await withPeers { center, silent, responding in
            try await waitUntil { await silent.count == 1 }
            try await waitUntil { await center.connectedApps.count == 1 }
            await center.stop()
            await center.start()
            try await waitUntil { await silent.count == 2 }
            try await waitUntil { await responding.count == 2 }
            let replacement = try await silent.session(at: 1)
            try await silent.hello(replacement)
            try await waitUntil { await center.connectedApps.count == 2 }
            let old = try await silent.session(at: 0)
            await #expect(throws: NectoSocketStream.Failure.self) {
                try await old.handshake(timeout: .seconds(3)) {
                    try await old.receive(NectoHandshakeAck.self)
                }
            }
            #expect(await center.connectedApps.count == 2)
        }
    }
}
