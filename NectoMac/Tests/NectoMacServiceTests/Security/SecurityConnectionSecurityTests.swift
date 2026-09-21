//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Security
import NectoModel
import NectoTransport
import Testing
@testable import NectoSDK
@testable import NectoMacService
@testable import NectoTransport

@Suite("Optional connection security", .serialized, .timeLimit(.minutes(1)))
struct ConnectionSecurityTests {
    @Test("a non-extractable Keychain key completes real TLS and bidirectional framing")
    func keychainTLS() async throws {
        let fixture = try CredentialFixture()
        var error: Unmanaged<CFError>?
        #expect(SecKeyCopyExternalRepresentation(fixture.identity.privateKey, &error) == nil)
        #expect(error != nil)
        _ = error?.takeRetainedValue()
        try await withSockets(tcp: true) { pair in
            let (device, host) = try await secureSessions(pair, identity: fixture.identity)
            #expect(pair.device.isTLSReady)
            #expect(pair.host.isTLSReady)
            #expect(try await pair.device.negotiatedTLSVersion() == .tlsv13)
            #expect(try await pair.host.negotiatedTLSVersion() == .tlsv13)
            let request = Data("request inside TLS".utf8)
            try await host.send(request)
            #expect(try await device.receive() == request)
            let response = Data("response inside TLS".utf8)
            try await device.send(response)
            #expect(try await host.receive() == response)
        }
    }

    @Test("only an authenticated host can register plugins and invoke the actual SDK runtime")
    func authenticatedRuntime() async throws {
        let fixture = try CredentialFixture()
        let runtime = NectoSDKRuntime()
        let calls = SecurityLocked(0)
        #expect(runtime.register(ProbePlugin(calls: calls)))
        defer { runtime.stop() }
        try await withSockets { pair in
            let worker = Task {
                let session = try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID)
                await runtime.accept(session: session)
            }
            defer { pair.close(); worker.cancel() }
            let host = try await SecurityTestHandshake.host(stream: pair.host) { try fixture.store.identity(bundleID: $0) }
            try await acceptSDKHello(host)
            try await invokeProbe(host)
            #expect(calls.withValue { $0 } == 1)
            host.close()
            try await worker.value
        }
    }

    @Test("missing and wrong host keys never admit a session or invoke a plugin", arguments: [false, true])
    func unauthorizedHost(wrongKey: Bool) async throws {
        let fixture = try CredentialFixture()
        let impostor = try CredentialFixture()
        let admitted = SecurityLocked(false)
        let calls = SecurityLocked(0)
        let runtime = NectoSDKRuntime()
        #expect(runtime.register(ProbePlugin(calls: calls)))
        defer { runtime.stop() }
        try await withSockets { pair in
            let worker = Task {
                do {
                    let session = try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID)
                    admitted.withValue { $0 = true }
                    await runtime.accept(session: session)
                    return true
                } catch { return false }
            }
            defer { pair.close(); worker.cancel() }
            await #expect(throws: (any Error).self) {
                _ = try await SecurityTestHandshake.host(stream: pair.host) { _ in wrongKey ? impostor.identity : nil }
            }
            #expect(await worker.value == false)
            #expect(admitted.withValue { $0 } == false)
            #expect(calls.withValue { $0 } == 0)
            #expect(!pair.device.isTLSReady)
            await #expect(throws: (any Error).self) { try await pair.device.write(Data("plaintext fallback".utf8)) }
        }
    }

    @Test("a plaintext imitation cannot call a plugin on a protected SDK")
    func plaintextImpostor() async throws {
        let fixture = try CredentialFixture()
        let admitted = SecurityLocked(false)
        let runtime = NectoSDKRuntime()
        let calls = SecurityLocked(0)
        #expect(runtime.register(ProbePlugin(calls: calls)))
        defer { runtime.stop() }
        try await withSockets { pair in
            let worker = Task {
                do {
                    let session = try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID)
                    admitted.withValue { $0 = true }
                    await runtime.accept(session: session)
                } catch {}
            }
            defer { pair.close(); worker.cancel() }
            let attacker = NectoMessageSession(stream: pair.host)
            let offer = try await attacker.receive()
            #expect(String(decoding: offer, as: UTF8.self).contains("necto.security"))
            try await attacker.send(NectoHandshakeAck(accepted: true))
            try? await attacker.send(NectoEnvelope(type: .pluginInvoke, encoding: NectoPluginInvocation(
                requestID: "attack", name: "necto.device.probe.echo", version: 1, kind: .once, input: [:]
            )))
            await worker.value
            #expect(!admitted.withValue { $0 })
            #expect(calls.withValue { $0 } == 0)
            #expect(!pair.device.isTLSReady)
        }
    }

    @Test("invalid configured pins fail closed instead of silently disabling security", arguments: ["", "not-base64", Data(repeating: 0, count: 65).base64EncodedString()])
    func invalidPin(_ pin: String) async throws {
        try await withSockets { pair in
            await #expect(throws: NectoSecurityError.invalidPublicKey) {
                _ = try await SecurityTestHandshake.device(stream: pair.device, publicKey: pin, appBundleID: CredentialFixture.bundleID)
            }
            await #expect(throws: (any Error).self) { _ = try await pair.host.read(count: 1) }
        }
    }

    @Test("debug payloads are encrypted in both directions, including large binary frames")
    func encryptedWire() async throws {
        let fixture = try CredentialFixture()
        let hostWire = SecurityLocked(Data())
        let deviceWire = SecurityLocked(Data())
        try await withSockets(deviceWire: { direction, bytes in
            if direction == .outgoing { deviceWire.withValue { $0.append(bytes) } }
            return bytes
        }, hostWire: { direction, bytes in
            if direction == .outgoing { hostWire.withValue { $0.append(bytes) } }
            return bytes
        }) { pair in
            let (device, host) = try await secureSessions(pair, identity: fixture.identity)
            hostWire.withValue { $0.removeAll() }
            deviceWire.withValue { $0.removeAll() }
            let marker = Data("PRIVATE-DEBUG-PAYLOAD-".utf8)
            var data = marker
            data.append(contentsOf: (0..<(256 * 1024)).map { UInt8($0 % 251) })
            let payload = data
            try await host.send(payload)
            #expect(try await device.receive() == payload)
            try await device.send(payload)
            #expect(try await host.receive() == payload)
            for wire in [hostWire, deviceWire] {
                #expect(wire.withValue { !$0.isEmpty })
                #expect(wire.withValue { $0.range(of: marker) == nil })
                #expect(wire.withValue { $0.count > payload.count })
            }
        }
    }

    @Test("tampered and replayed TLS records are rejected", arguments: [false, true])
    func recordIntegrity(replay: Bool) async throws {
        let fixture = try CredentialFixture()
        let state = SecurityLocked((armed: false, previous: Data()))
        try await withSockets(hostWire: { direction, bytes in
            guard direction == .outgoing else { return bytes }
            return state.withValue { state in
                if state.armed {
                    state.armed = false
                    if replay { return state.previous }
                    var damaged = bytes
                    if !damaged.isEmpty { damaged[damaged.count - 1] ^= 1 }
                    return damaged
                }
                state.previous = bytes
                return bytes
            }
        }) { pair in
            let (device, host) = try await secureSessions(pair, identity: fixture.identity)
            try await host.send(Data("first message".utf8))
            #expect(try await device.receive() == Data("first message".utf8))
            state.withValue { $0.armed = true }
            try await host.send(Data("second message".utf8))
            do {
                _ = try await device.handshake(timeout: .seconds(3)) { try await device.receive() }
                Issue.record("An altered TLS record reached the application")
            } catch {
                #expect((error as? URLError)?.code != .timedOut)
                #expect(!pair.device.isTLSReady)
            }
        }
    }

    @Test("a failed competing authentication does not evict an established SDK session")
    func failedCompetitor() async throws {
        let fixture = try CredentialFixture()
        let runtime = NectoSDKRuntime()
        let calls = SecurityLocked(0)
        #expect(runtime.register(ProbePlugin(calls: calls)))
        defer { runtime.stop() }
        try await withSockets { established in
            let (app, host) = try await secureSessions(established, identity: fixture.identity)
            let worker = Task { await runtime.accept(session: app) }
            defer { established.close(); worker.cancel() }
            try await acceptSDKHello(host)
            try await invokeProbe(host)
            try await withSockets { competitor in
                let attempt = Task {
                    do {
                        let session = try await SecurityTestHandshake.device(stream: competitor.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID)
                        await runtime.accept(session: session)
                        return true
                    } catch { return false }
                }
                defer { competitor.close(); attempt.cancel() }
                await #expect(throws: NectoSecurityError.unauthorized) {
                    _ = try await SecurityTestHandshake.host(stream: competitor.host) { _ in nil }
                }
                #expect(await attempt.value == false)
            }
            try await invokeProbe(host)
            #expect(calls.withValue { $0 } == 2)
            host.close()
            await worker.value
        }
    }

    @Test("rewriting discovery as a legacy hello cannot disable SDK authentication")
    func strippedSecurityOffer() async throws {
        let fixture = try CredentialFixture()
        let legacyHello = try JSONEncoder().encode(NectoHandshakeHello(
            appBundleID: CredentialFixture.bundleID, appName: "Forged legacy offer", deviceName: "iPhone", sdkVersion: "0.0.1"
        ))
        let rewritten = SecurityLocked(false)
        let admitted = SecurityLocked(false)
        try await withSockets(deviceWire: { direction, bytes in
            guard direction == .outgoing else { return bytes }
            return rewritten.withValue { alreadyRewritten in
                if alreadyRewritten { return bytes }
                alreadyRewritten = true
                return frame(legacyHello)
            }
        }) { pair in
            let attempt = Task {
                do {
                    _ = try await SecurityTestHandshake.device(stream: pair.device, publicKey: fixture.identity.publicKey, appBundleID: CredentialFixture.bundleID)
                    admitted.withValue { $0 = true }
                } catch {}
            }
            defer { pair.close(); attempt.cancel() }
            let fooledHost = try await SecurityTestHandshake.host(stream: pair.host) { _ in nil }
            #expect(try await fooledHost.receive() == legacyHello)
            try await fooledHost.send(NectoHandshakeAck(accepted: true))
            await attempt.value
            #expect(rewritten.withValue { $0 })
            #expect(!admitted.withValue { $0 })
            #expect(!pair.device.isTLSReady)
        }
    }
}
