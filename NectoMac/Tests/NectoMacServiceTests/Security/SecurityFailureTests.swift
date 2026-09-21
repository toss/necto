//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NIOPosix
import NectoModel
import NectoTransport
import Testing
@testable import NectoMacService
@testable import NectoTransport

@Suite("Negotiation and transport failures", .serialized, .timeLimit(.minutes(1)))
struct FailureTests {
    @Test("releasing a stream closes its socket without an explicit close")
    func releaseClosesSocket() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            var descriptors: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
            var device: NectoTLSStream? = try await NectoTLSStream.adopt(descriptor: descriptors[0], group: group)
            weak var released = device
            let host = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[1]))
            device = nil
            #expect(released == nil)
            do {
                _ = try await host.handshake(timeout: .seconds(3)) { try await host.receive() }
                Issue.record("A released stream left its socket open")
            } catch {
                #expect((error as? URLError)?.code != .timedOut)
            }
            host.close()
            try await group.shutdownGracefully()
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
    }

    @Test("unknown, incomplete, and malformed offers cannot fall back to legacy", arguments: [
        "{\"type\":\"necto.security\",\"version\":2,\"appBundleID\":\"com.example.app\"}",
        "{\"type\":\"necto.security\",\"appBundleID\":\"com.example.app\"}",
        "{\"type\":\"necto.security\",\"version\":1,\"appBundleID\":\"\"}",
        "{\"type\":\"other.security\",\"version\":1,\"appBundleID\":\"com.example.app\"}",
        "{\"type\":null}", "{}", "[]", "not json", "",
    ])
    func malformedOffer(_ offer: String) async throws {
        try await withSockets { pair in
            try await NectoMessageSession(stream: pair.device).send(Data(offer.utf8))
            await #expect(throws: (any Error).self) {
                _ = try await SecurityTestHandshake.host(stream: pair.host) { _ in
                    Issue.record("Invalid offers must not look up a private key")
                    return nil
                }
            }
            await #expect(throws: (any Error).self) { _ = try await pair.device.read(count: 1) }
        }
    }

    @Test("an unregistered bundle ID has no credential fallback")
    func unregisteredBundleID() async throws {
        let fixture = try CredentialFixture()
        try await withSockets { pair in
            let attempt = Task {
                try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: "com.example.impostor")
            }
            defer { pair.close(); attempt.cancel() }
            await #expect(throws: NectoSecurityError.unauthorized) {
                _ = try await SecurityTestHandshake.host(stream: pair.host) { try fixture.store.identity(bundleID: $0) }
            }
            await #expect(throws: (any Error).self) { _ = try await attempt.value }
        }
    }

    @Test("silent peers time out in discovery and TLS", arguments: [false, true])
    func timeout(duringTLS: Bool) async throws {
        let fixture = try CredentialFixture()
        try await withSockets { pair in
            do {
                if duringTLS {
                    _ = try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID, timeout: .milliseconds(100))
                } else {
                    _ = try await SecurityTestHandshake.host(stream: pair.device, timeout: .milliseconds(100)) { _ in nil }
                }
                Issue.record("A silent peer passed negotiation")
            } catch {
                #expect((error as? URLError)?.code == .timedOut)
            }
            #expect(!pair.device.isTLSReady)
            await #expect(throws: (any Error).self) { try await pair.device.write(Data([1])) }
        }
    }

    @Test("cancelling a pending TLS handshake closes the connection")
    func cancelHandshake() async throws {
        let fixture = try CredentialFixture()
        try await withSockets { pair in
            let task = Task {
                try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID)
            }
            _ = try await NectoMessageSession(stream: pair.host).receive()
            task.cancel()
            await #expect(throws: (any Error).self) { _ = try await task.value }
            #expect(!pair.device.isTLSReady)
            await #expect(throws: (any Error).self) { _ = try await pair.device.read(count: 1) }
        }
    }

    @Test("peer EOF during negotiation never becomes an authorized session")
    func peerEOF() async throws {
        let fixture = try CredentialFixture()
        try await withSockets { pair in
            let task = Task {
                try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID)
            }
            _ = try await NectoMessageSession(stream: pair.host).receive()
            pair.host.close()
            await #expect(throws: (any Error).self) { _ = try await task.value }
            #expect(!pair.device.isTLSReady)
        }
    }

    @Test("cancelling an encrypted receive unblocks it and closes its stream")
    func cancelRead() async throws {
        let fixture = try CredentialFixture()
        try await withSockets { pair in
            let (device, _) = try await secureSessions(pair, identity: fixture.identity)
            let read = Task { try await device.receive() }
            read.cancel()
            await #expect(throws: (any Error).self) { _ = try await read.value }
            #expect(!pair.device.isTLSReady)
            await #expect(throws: (any Error).self) { try await device.send(Data([1])) }
        }
    }

    @Test("oversized length prefixes fail without reading their payload")
    func oversizedFrame() async throws {
        try await withSockets { pair in
            try await pair.device.write(Data([255, 255, 255, 255]))
            await #expect(throws: NectoMessageSession.Failure.self) {
                _ = try await SecurityTestHandshake.host(stream: pair.host) { _ in nil }
            }
            await #expect(throws: (any Error).self) { _ = try await pair.device.read(count: 1) }
        }
    }

    @Test("truncated frames end on EOF instead of hanging")
    func truncatedFrame() async throws {
        try await withSockets { pair in
            try await pair.device.write(Data([0, 0, 0, 10, 1, 2]))
            pair.device.close()
            await #expect(throws: (any Error).self) {
                _ = try await SecurityTestHandshake.host(stream: pair.host) { _ in nil }
            }
        }
    }

    @Test("buffer limits reject a stalled reader")
    func bufferLimit() async throws {
        try await withSockets(limit: 64) { pair in
            let reading = Task { try await pair.host.read(count: 64) }
            try await pair.device.write(Data(repeating: 7, count: 65))
            await #expect(throws: NectoSecurityError.bufferLimit) { _ = try await reading.value }
            await #expect(throws: NectoSecurityError.bufferLimit) { _ = try await pair.host.read(count: 1) }
        }
    }

    @Test("fragmented plaintext headers and bodies retain exact framing")
    func fragmentedFrames() async throws {
        try await withSockets { pair in
            let expected = Data("fragmented frame".utf8)
            let sender = Task {
                for byte in frame(expected) { try await pair.device.write(Data([byte])) }
            }
            #expect(try await NectoMessageSession(stream: pair.host).receive() == expected)
            try await sender.value
        }
    }

    @Test("coalesced plaintext discovery and TLS ClientHello are upgraded without losing bytes")
    func coalescedUpgrade() async throws {
        let fixture = try CredentialFixture()
        let state = SecurityLocked((held: Data(), joined: false))
        try await withSockets(deviceWire: { direction, bytes in
            guard direction == .outgoing else { return bytes }
            return state.withValue { state in
                if state.joined { return bytes }
                if state.held.isEmpty { state.held = bytes; return Data() }
                state.joined = true
                return state.held + bytes
            }
        }) { pair in
            let (device, host) = try await secureSessions(pair, identity: fixture.identity)
            #expect(state.withValue { $0.joined })
            try await host.send(Data("coalesced upgrade".utf8))
            #expect(try await device.receive() == Data("coalesced upgrade".utf8))
        }
    }
}
