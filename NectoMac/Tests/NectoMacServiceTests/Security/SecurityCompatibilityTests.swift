//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NIOPosix
import NectoModel
import NectoTransport
import Testing
@testable import NectoSDK
@testable import NectoMacService
@testable import NectoTransport

@Suite("Existing connection compatibility", .serialized, .timeLimit(.minutes(1)))
struct CompatibilityTests {
    @Test("the unchanged SDK runtime and socket stream work with the new host gate")
    func oldSDKToNewHost() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            var descriptors: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
            let app = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[0]))
            let stream = try await NectoTLSStream.adopt(descriptor: descriptors[1], group: group)
            let runtime = NectoSDKRuntime()
            let calls = SecurityLocked(0)
            #expect(runtime.register(ProbePlugin(calls: calls)))
            let worker = Task { await runtime.accept(session: app) }
            do {
                let host = try await SecurityTestHandshake.host(stream: stream) { _ in
                    Issue.record("A legacy SDK must not look up a private key")
                    return nil
                }
                try await acceptSDKHello(host)
                try await invokeProbe(host)
                #expect(calls.withValue { $0 } == 1)
                #expect(!stream.isTLSReady)
            } catch {
                stream.close(); app.close(); runtime.stop(); worker.cancel()
                await worker.value
                throw error
            }
            stream.close(); app.close(); runtime.stop()
            await worker.value
            try await group.shutdownGracefully()
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
    }

    @Test("an unconfigured SDK works with old and new hosts", arguments: [false, true])
    func unconfiguredSDK(newHost: Bool) async throws {
        let runtime = NectoSDKRuntime()
        let calls = SecurityLocked(0)
        #expect(runtime.register(ProbePlugin(calls: calls)))
        defer { runtime.stop() }
        try await withSockets { pair in
            let worker = Task {
                let session = try await SecurityTestHandshake.device(stream: pair.device, publicKey: nil, appBundleID: CredentialFixture.bundleID)
                await runtime.accept(session: session)
            }
            defer { pair.close(); worker.cancel() }
            let host: NectoMessageSession
            if newHost {
                host = try await SecurityTestHandshake.host(stream: pair.host) { _ in
                    Issue.record("Unconfigured apps must not request credentials")
                    return nil
                }
            } else {
                host = NectoMessageSession(stream: pair.host)
            }
            try await acceptSDKHello(host)
            try await invokeProbe(host)
            #expect(!pair.device.isTLSReady)
            #expect(!pair.host.isTLSReady)
            #expect(calls.withValue { $0 } == 1)
            host.close()
            try await worker.value
        }
    }

    @Test("legacy first-frame bytes and a coalesced following frame are preserved exactly")
    func coalescedLegacyFrames() async throws {
        try await withSockets { pair in
            let hello = Data("""
            { "appBundleID":"com.example.old", "appName":"Old", "deviceName":"iPhone", "osVersion":"17", "appVersion":"1", "sdkVersion":"0.0.1", "protocolVersion":1, "futureField":42 }
            """.utf8)
            let next = Data("legacy second frame".utf8)
            try await pair.device.write(frame(hello) + frame(next))
            let host = try await SecurityTestHandshake.host(stream: pair.host) { _ in nil }
            #expect(try await host.receive() == hello)
            #expect(try await host.receive() == next)
            try await host.send(Data("ack".utf8))
            #expect(try await NectoMessageSession(stream: pair.device).receive() == Data("ack".utf8))
        }
    }

    @Test("unsupported legacy protocol versions still reach the existing version check")
    func legacyVersionCheck() async throws {
        try await withSockets { pair in
            let hello = NectoHandshakeHello(protocolVersion: 999, appBundleID: "com.example.old", appName: "Old", deviceName: "iPhone", sdkVersion: "0.0.1")
            try await NectoMessageSession(stream: pair.device).send(hello)
            let host = try await SecurityTestHandshake.host(stream: pair.host) { _ in nil }
            let received = try await host.receive(NectoHandshakeHello.self)
            #expect(received == hello)
            #expect(NectoHandshakeAck.evaluate(received).rejection == .unsupportedProtocolVersion)
        }
    }

    @Test("an old host cannot downgrade a protected SDK to plaintext")
    func oldHostToProtectedSDK() async throws {
        let fixture = try CredentialFixture()
        try await withSockets { pair in
            let attempt = Task {
                try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID)
            }
            defer { pair.close(); attempt.cancel() }
            let oldHost = NectoMessageSession(stream: pair.host)
            await #expect(throws: DecodingError.self) { _ = try await oldHost.receive(NectoHandshakeHello.self) }
            oldHost.close()
            await #expect(throws: (any Error).self) { _ = try await attempt.value }
            #expect(!pair.device.isTLSReady)
        }
    }

    @Test("disconnecting and reconnecting the same SDK needs no runtime restart", arguments: [false, true])
    func reconnect(protected: Bool) async throws {
        let fixture = try CredentialFixture()
        let runtime = NectoSDKRuntime()
        let calls = SecurityLocked(0)
        #expect(runtime.register(ProbePlugin(calls: calls)))
        defer { runtime.stop() }
        for _ in 0..<3 {
            try await withSockets { pair in
                let worker = Task {
                    let app = try await SecurityTestHandshake.device(stream: pair.device, publicKey: protected ? fixture.identity.publicKey : nil, appBundleID: CredentialFixture.bundleID)
                    await runtime.accept(session: app)
                }
                defer { pair.close(); worker.cancel() }
                let host = try await SecurityTestHandshake.host(stream: pair.host) { _ in fixture.identity }
                try await acceptSDKHello(host)
                try await invokeProbe(host)
                host.close()
                try await worker.value
            }
        }
        #expect(calls.withValue { $0 } == 3)
    }
}

func frame(_ payload: Data) -> Data {
    var result = Data()
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { result.append(contentsOf: $0) }
    return result + payload
}
