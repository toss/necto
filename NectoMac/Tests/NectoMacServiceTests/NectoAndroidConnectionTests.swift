// Copyright (c) 2026 Viva Republica, Inc.

import Foundation
import NectoModel
import NectoSDK
import NectoTransport
import Testing
@testable import NectoMacService

@Suite("Private Android connections", .serialized, .timeLimit(.minutes(1)))
struct NectoAndroidConnectionTests {
    private final class UnixListener {
        let directory = "/tmp/necto-test-" + UUID().uuidString
        let acceptor: NectoSocketAcceptor
        var path: String { directory + "/adb.sock" }

        init() throws {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var owned = true
            defer { if owned { Darwin.close(fd) } }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let name = directory + "/adb.sock"
            name.withCString { source in
                withUnsafeMutableBytes(of: &address.sun_path) { destination in
                    _ = memcpy(destination.baseAddress!, source, strlen(source) + 1)
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, listen(fd, 4) == 0 else { throw POSIXError(.EIO) }
            acceptor = try NectoSocketAcceptor(descriptor: fd)
            owned = false
        }

        deinit {
            acceptor.close()
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    private actor Peer {
        var sessions: [NectoMessageSession] = []
        var task: Task<Void, Never>?
        var count: Int { sessions.count }

        func start(_ incoming: AsyncThrowingStream<NectoMessageSession, any Error>, app: String = "dev.necto.fixture") {
            task = Task {
                do {
                    for try await session in incoming {
                        sessions.append(session)
                        try await session.send(NectoHandshakeHello(appBundleID: app, appName: "Fixture",
                            appVersion: "1", deviceName: "Fixture", sdkVersion: "1", simulatorID: "ios-probe"))
                        _ = try? await session.receive(NectoHandshakeAck.self)
                    }
                } catch {}
            }
        }

        func disconnect() { sessions.last?.close() }
        func stop() { task?.cancel(); for session in sessions { session.close() } }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A forwarded socket must be owned by this user inside a private directory")
    func privatePath() async throws {
        let listener = try UnixListener()
        let endpoint = NectoConnectionCenter.AndroidEndpoint(serial: "phone", socketPath: listener.path, appBundleID: "dev.necto.fixture")
        let session = try await endpoint.connect()
        session.close()
        try #require(chmod(listener.directory, 0o755) == 0)
        await #expect(throws: POSIXError.self) { try await endpoint.connect() }
        try #require(chmod(listener.directory, 0o700) == 0)
        let link = listener.directory + "/alias.sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: listener.path)
        let alias = NectoConnectionCenter.AndroidEndpoint(serial: "phone", socketPath: link, appBundleID: "dev.necto.fixture")
        await #expect(throws: POSIXError.self) { try await alias.connect() }
    }

    @Test("Android and iOS reconnect independently using their original message contract")
    func mixedPlatforms() async throws {
        let android = try UnixListener()
        let ios = NectoDeviceListener(port: 0)
        try ios.start()
        defer { ios.stop() }
        let androidPeer = Peer(), iosPeer = Peer()
        await androidPeer.start(android.acceptor.sessions)
        await iosPeer.start(ios.sessions())
        let center = NectoConnectionCenter(port: ios.port, probeInterval: .milliseconds(30),
            deviceEvents: { AsyncThrowingStream { $0.finish() } },
            androidEndpoint: .init(serial: "emulator-5554", socketPath: android.path, appBundleID: "dev.necto.fixture"))
        await center.start()
        do {
            try await wait { await center.connectedApps.count == 2 }
            #expect(Set(await center.connectedApps.map(\.connection)) == [.simulator, .androidEmulator])
            await androidPeer.disconnect()
            try await wait { await androidPeer.count == 2 }
            #expect(await iosPeer.count == 1)
            await iosPeer.disconnect()
            try await wait { await iosPeer.count == 2 }
            try await wait { await center.connectedApps.count == 2 }
            #expect(await androidPeer.count == 2)
        } catch {
            await center.stop(); await androidPeer.stop(); await iosPeer.stop()
            throw error
        }
        await center.stop(); await androidPeer.stop(); await iosPeer.stop()
    }

    @Test("A different app cannot claim the selected Android target")
    func wrongApplication() async throws {
        let listener = try UnixListener()
        let peer = Peer()
        await peer.start(listener.acceptor.sessions, app: "dev.other.app")
        let center = NectoConnectionCenter(probeInterval: .milliseconds(30),
            androidEndpoint: .init(serial: "phone", socketPath: listener.path, appBundleID: "dev.necto.fixture"),
            appleDiscoveryEnabled: false)
        await center.start()
        do {
            try await wait { await peer.count >= 2 }
            #expect(await center.connectedApps.isEmpty)
        } catch {
            await center.stop(); await peer.stop()
            throw error
        }
        await center.stop(); await peer.stop()
    }
}
