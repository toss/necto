//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoTransport
import NectoModel
import Foundation
import Testing

@testable import NectoMacService

private func signalled(_ semaphore: DispatchSemaphore, within seconds: Int) -> Bool {
    semaphore.wait(timeout: .now() + .seconds(seconds)) == .success
}

private final class DelayedCloseStream: NectoByteStream, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let base: NectoSocketStream
    private let lock = NSLock()
    private var closing = false

    init(descriptor: Int32) { base = NectoSocketStream(descriptor: descriptor) }

    func write(_ data: Data) async throws { try await base.write(data) }
    func read(count: Int) async throws -> Data { try await base.read(count: count) }
    func close() {
        let first = lock.withLock {
            guard !closing else { return false }
            closing = true
            return true
        }
        guard first else { return }
        entered.signal()
        release.wait()
        base.close()
    }
}

@Suite("Which ports a transport dials")
struct NectoConnectionCenterTests {
    @Test("a port range near UInt16.max is clipped rather than overflowing")
    func clipsPortRange() {
        #expect(NectoConnectionCenter.portsToDial(from: 65533, skipping: [65534]) == [65533, 65535])
        #expect(NectoConnectionCenter.portsToDial(from: 65535, skipping: []) == [65535])
    }

    private let base = NectoTransportDefaults.devicePort

    @Test("dials the whole span while nothing has answered")
    func dialsTheWholeSpan() {
        let ports = NectoConnectionCenter.portsToDial(from: base, skipping: [])

        #expect(ports == Array(base ..< base + NectoTransportDefaults.portSpan))
    }

    @Test("keeps offering the later ports after the first app answers")
    func keepsOfferingLaterPorts() {
        let ports = NectoConnectionCenter.portsToDial(from: base, skipping: [base])

        // The second app on a device slid one port along, so the port it settled on
        // has to stay in the list — this is what made only one build show up.
        #expect(ports.first == base + 1)
        #expect(!ports.contains(base))
    }

    @Test("never dials a port that already carries a session")
    func skipsConnectedPorts() {
        let ports = NectoConnectionCenter.portsToDial(from: base, skipping: [base, base + 1])

        #expect(!ports.contains(base))
        #expect(!ports.contains(base + 1))
        #expect(ports.count == Int(NectoTransportDefaults.portSpan) - 2)
    }

    @Test("stops when the whole span has answered")
    func stopsWhenTheSpanIsFull() {
        let full = Set(base ..< base + NectoTransportDefaults.portSpan)

        #expect(NectoConnectionCenter.portsToDial(from: base, skipping: full).isEmpty)
    }
}

@Suite("Host connection lifecycle", .timeLimit(.minutes(1)))
struct NectoHostConnectionLifecycleTests {
    @Test("a slow socket close cannot block target discovery after disconnect")
    func targetDiscoveryDuringClose() async throws {
        let center = NectoConnectionCenter()
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let app = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[0]))
        let delayed = DelayedCloseStream(descriptor: descriptors[1])
        let host = NectoMessageSession(stream: delayed)
        defer {
            delayed.release.signal()
            app.close()
            host.close()
        }

        let accepting = Task {
            try await center.accept(session: host, deviceID: "simulator", connection: .simulator, usbDeviceID: nil)
        }
        try await app.send(NectoHandshakeHello(
            appBundleID: "com.example.close", appName: "Close test", appVersion: "1.0.0",
            deviceName: "Test simulator", sdkVersion: "0.4.2", simulatorID: "test-simulator"
        ))
        #expect(try await app.receive(NectoHandshakeAck.self).accepted)
        let reader = try #require(try await accepting.value)
        app.close()

        let closing = await Task.detached {
            signalled(delayed.entered, within: 5)
        }.value
        try #require(closing, "The host did not start closing the disconnected socket")

        let answered = DispatchSemaphore(value: 0)
        let discovery = Task.detached {
            let apps = await center.connectedApps
            answered.signal()
            return apps
        }
        let responsive = await Task.detached {
            signalled(answered, within: 3)
        }.value
        delayed.release.signal()
        #expect(responsive, "Target discovery waited for socket close")
        #expect(await discovery.value.isEmpty)
        await reader.value
    }

    @Test("a silent hello is bounded by the production handshake deadline")
    func silentHandshake() async throws {
        let center = NectoConnectionCenter()
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let app = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[0]))
        let host = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[1]))
        defer { app.close(); host.close() }
        let started = ContinuousClock.now
        await #expect(throws: URLError.self) {
            try await center.accept(session: host, deviceID: "simulator", connection: .simulator, usbDeviceID: nil)
        }
        #expect(started.duration(to: .now) < .seconds(15))
        #expect(await center.connectedApps.isEmpty)
        await #expect(throws: NectoSocketStream.Failure.self) {
            try await app.handshake(timeout: .seconds(3)) {
                try await app.receive(NectoHandshakeAck.self)
            }
        }
    }

    @Test("cancelling an incomplete hello releases the socket", arguments: 0..<10)
    func cancelHandshake(_: Int) async throws {
        let center = NectoConnectionCenter()
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let stream = NectoSocketStream(descriptor: descriptors[0])
        let app = NectoMessageSession(stream: stream)
        let host = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[1]))
        defer { app.close(); host.close() }
        let accepting = Task {
            try await center.accept(session: host, deviceID: "simulator", connection: .simulator, usbDeviceID: nil)
        }
        try await stream.write(Data([0]))
        accepting.cancel()
        await #expect(throws: (any Error).self) { try await accepting.value }
        #expect(await center.connectedApps.isEmpty)
        await #expect(throws: NectoSocketStream.Failure.self) {
            try await app.handshake(timeout: .seconds(3)) {
                try await app.receive(NectoHandshakeAck.self)
            }
        }
    }

    private struct Peer {
        let app: NectoMessageSession
        let reader: Task<Void, Never>
        let target: NectoTarget
    }

    private func connect(
        _ center: NectoConnectionCenter,
        bundleID: String = "com.example.lifecycle",
        simulatorID: String = "test-simulator",
        version: String = "1.0.0"
    ) async throws -> Peer {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let app = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[0]))
        let host = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[1]))
        let accepting = Task {
            try await center.accept(session: host, deviceID: "simulator", connection: .simulator, usbDeviceID: nil)
        }
        do {
            try await app.handshake(timeout: .seconds(3)) {
                try await app.send(NectoHandshakeHello(
                    appBundleID: bundleID, appName: "Lifecycle test", appVersion: version,
                    deviceName: "Test simulator", sdkVersion: "0.4.2", simulatorID: simulatorID
                ))
                #expect(try await app.receive(NectoHandshakeAck.self).accepted)
            }
            let reader = try #require(try await accepting.value)
            return Peer(app: app, reader: reader, target: NectoTarget(deviceID: simulatorID, appBundleID: bundleID))
        } catch {
            app.close()
            host.close()
            accepting.cancel()
            _ = try? await accepting.value
            throw error
        }
    }

    private func expectRoundTrip(_ center: NectoConnectionCenter, peer: Peer) async throws {
        let outgoing = try NectoEnvelope(type: .pluginCancel, encoding: NectoPluginCancel(requestID: "current-session"))
        try await peer.app.handshake(timeout: .seconds(3)) {
            try await center.send(outgoing, to: peer.target)
            let received = try await peer.app.receive(NectoEnvelope.self)
            #expect(try received.decode(NectoPluginCancel.self).requestID == "current-session")
        }
    }

    @Test("old reader cleanup cannot remove its replacement", arguments: 0..<20)
    func replacementSurvivesOldCleanup(_: Int) async throws {
        let center = NectoConnectionCenter()
        let old = try await connect(center)
        defer { old.app.close() }
        let replacement = try await connect(center, version: "2.0.0")
        defer { replacement.app.close() }

        await old.reader.value
        let apps = await center.connectedApps
        #expect(apps.count == 1)
        #expect(apps.first?.appVersion == "2.0.0")
        try await expectRoundTrip(center, peer: replacement)
        await center.stop()
        await replacement.reader.value
        #expect(await center.connectedApps.isEmpty)
    }

    @Test("stop closes readers and a fresh session can reconnect")
    func stopAndReconnect() async throws {
        let center = NectoConnectionCenter()
        let first = try await connect(center)
        defer { first.app.close() }
        await center.stop()
        await first.reader.value
        #expect(await center.connectedApps.isEmpty)
        await #expect(throws: NectoBridgeError.self) {
            try await center.send(NectoEnvelope(type: .pluginCancel, encoding: NectoPluginCancel(requestID: "stopped")), to: first.target)
        }
        let second = try await connect(center)
        defer { second.app.close() }
        try await expectRoundTrip(center, peer: second)
        await center.stop()
        await second.reader.value
    }

    @Test("disconnecting one target preserves other apps and simulators")
    func independentTargets() async throws {
        let center = NectoConnectionCenter()
        let first = try await connect(center)
        let otherApp = try await connect(center, bundleID: "com.example.other")
        let otherSimulator = try await connect(center, simulatorID: "second-simulator")
        defer { first.app.close(); otherApp.app.close(); otherSimulator.app.close() }
        #expect(await center.connectedApps.count == 3)
        first.app.close()
        await first.reader.value
        #expect(await center.connectedApps.count == 2)
        try await expectRoundTrip(center, peer: otherApp)
        try await expectRoundTrip(center, peer: otherSimulator)
        await center.stop()
        await otherApp.reader.value
        await otherSimulator.reader.value
    }
}
