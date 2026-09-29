//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
@testable import NectoTransport
import Testing
@testable import NectoSDK
@testable import NectoMacService

private let securityHello = NectoHandshakeHello(
    appBundleID: CredentialFixture.bundleID, appName: "Protected Example",
    deviceName: "Test iPhone", osVersion: "26", sdkVersion: "1", simulatorID: "security-simulator"
)

private func rawSessions(tcp: Bool = false) throws -> (device: NectoMessageSession, host: NectoMessageSession) {
    let pair = try securitySocketDescriptors(tcp: tcp)
    return (NectoMessageSession(stream: NectoSocketStream(descriptor: pair.0)),
            NectoMessageSession(stream: NectoSocketStream(descriptor: pair.1)))
}

private func securityCenter(
    identity: @escaping @Sendable (String) async throws -> NectoTLSIdentity?
) -> NectoConnectionCenter {
    NectoConnectionCenter(port: 0, probeInterval: .seconds(1), deviceEvents: { AsyncThrowingStream { $0.finish() } }, identity: identity)
}

private func admit(_ center: NectoConnectionCenter, _ session: NectoMessageSession) async throws -> Task<Void, Never>? {
    try await center.accept(session: session, deviceID: "simulator", connection: .simulator, usbDeviceID: nil, localPort: 12345)
}

private func nextEnvelope(_ stream: AsyncStream<NectoEnvelope>) async throws -> NectoEnvelope {
    try await withThrowingTaskGroup(of: NectoEnvelope.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try #require(await iterator.next())
        }
        group.addTask { try await Task.sleep(for: .seconds(3)); throw URLError(.timedOut) }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Suite("Production SDK and host authentication", .serialized, .timeLimit(.minutes(1)))
struct SecurityIntegrationTests {
    @Test("delayed private-key approval preserves pending sessions and allows recovery after cancellation", arguments: [false, true])
    func delayedKeychainApproval(cancelBeforeApproval: Bool) async throws {
        let fixture = try CredentialFixture()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); entered.continuation.finish() }
        NectoKeychainSigningQueue.shared.submit(keyID: fixture.identity.publicKey) {
            entered.continuation.yield(())
            release.wait()
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        let calls = SecurityLocked(0)
        let sdk = NectoSDKRuntime(hello: { securityHello })
        #expect(sdk.register(ProbePlugin(calls: calls)))
        let credentialReady = AsyncStream<Void>.makeStream()
        defer { credentialReady.continuation.finish() }
        let center = securityCenter {
            let identity = try fixture.store.identity(bundleID: $0)
            credentialReady.continuation.yield(())
            return identity
        }
        let events = AsyncStream<NectoEnvelope>.makeStream()
        let received = SecurityLocked(0)
        defer { events.continuation.finish() }
        await center.onMessage { envelope, _ in
            received.withValue { $0 += 1 }
            events.continuation.yield(envelope)
        }
        let raw = try rawSessions(tcp: true)
        defer { raw.device.close(); raw.host.close(); sdk.stop() }
        let pin = try NectoPublicKeyPin(fixture.identity.publicKey)
        let worker = Task { await sdk.accept(session: raw.device, publicKey: pin) }
        let admitting = Task { try await admit(center, raw.host) }
        defer { worker.cancel(); admitting.cancel() }
        var credentialIterator = credentialReady.stream.makeAsyncIterator()
        _ = await credentialIterator.next()
        // Exceed both the former 3-second TLS limit and 10-second outer handshake limit.
        // Credential lookup confirms discovery, not that the TLS signature is already queued.
        try await Task.sleep(for: .seconds(11))
        #expect(await center.connectedApps.isEmpty)
        #expect(await center.unauthorizedApps.isEmpty)
        #expect(calls.withValue { $0 } == 0)
        #expect(received.withValue { $0 } == 0)
        var recoveredWorker: Task<Void, Never>?
        var recoveredSessions: (device: NectoMessageSession, host: NectoMessageSession)?
        defer {
            recoveredWorker?.cancel()
            recoveredSessions?.device.close()
            recoveredSessions?.host.close()
        }
        let reader: Task<Void, Never>
        if cancelBeforeApproval {
            admitting.cancel()
            await #expect(throws: CancellationError.self) { try await admitting.value }
            await worker.value
            #expect(await center.connectedApps.isEmpty)
            #expect(await center.unauthorizedApps.isEmpty)
            #expect(received.withValue { $0 } == 0)
            #expect(calls.withValue { $0 } == 0)
            release.signal()
            let fresh = try rawSessions(tcp: true)
            recoveredSessions = fresh
            recoveredWorker = Task { await sdk.accept(session: fresh.device, publicKey: pin) }
            reader = try #require(try await admit(center, fresh.host))
        } else {
            release.signal()
            reader = try #require(try await admitting.value)
        }
        #expect(try await nextEnvelope(events.stream).type == .pluginRegister)
        #expect(await center.connectedApps.count == 1)
        let app = try #require(await center.connectedApps.first)
        try await center.send(NectoEnvelope(type: .pluginInvoke, encoding: NectoPluginInvocation(
            requestID: "after-approval", name: "necto.device.probe.echo", version: 1,
            kind: .once, input: ["approved": true]
        )), to: app.target)
        let result = try await nextEnvelope(events.stream).decode(NectoPluginResult.self)
        #expect(result.output == ["approved": true])
        #expect(calls.withValue { $0 } == 1)
        await center.stop()
        await worker.value
        await recoveredWorker?.value
        await reader.value
    }

    @Test("two registered apps share a key while an unregistered app with the same pin is denied")
    func sharedKeyAcrossApps() async throws {
        let fixture = try CredentialFixture()
        let material = try CredentialFixture.generate(in: fixture.directory)
        let bundles = ["com.example.shared.first", "com.example.shared.second"]
        for bundle in bundles {
            try fixture.store.install(bundleID: bundle, privateKeyPEM: material.key, certificateDER: material.certificate)
        }
        let identity = try #require(try fixture.store.identity(bundleID: bundles[0]))
        let pin = try NectoPublicKeyPin(identity.publicKey)
        let center = securityCenter { try fixture.store.identity(bundleID: $0) }
        let events = AsyncStream<NectoEnvelope>.makeStream()
        await center.onMessage { envelope, _ in events.continuation.yield(envelope) }
        var workers: [Task<Void, Never>] = []
        var readers: [Task<Void, Never>] = []
        var runtimes: [NectoSDKRuntime] = []
        defer { runtimes.forEach { $0.stop() } }
        for (index, bundle) in (bundles + ["com.example.shared.unregistered"]).enumerated() {
            let calls = SecurityLocked(0)
            let sdk = NectoSDKRuntime(hello: {
                NectoHandshakeHello(appBundleID: bundle, appName: "Protected",
                    deviceName: "Test iPhone", sdkVersion: "1", simulatorID: "shared-key-simulator")
            })
            runtimes.append(sdk)
            #expect(sdk.register(ProbePlugin(calls: calls)))
            let pair = try rawSessions(tcp: true)
            workers.append(Task { await sdk.accept(session: pair.device, publicKey: pin) })
            let reader = try await center.accept(session: pair.host,
                deviceID: "simulator", connection: .simulator, usbDeviceID: nil, localPort: UInt16(12345 + index))
            if let reader {
                readers.append(reader)
                #expect(bundles.contains(bundle))
                #expect(try await nextEnvelope(events.stream).type == .pluginRegister)
                let app = try #require(await center.connectedApps.first { $0.appBundleID == bundle })
                try await center.send(NectoEnvelope(type: .pluginInvoke, encoding: NectoPluginInvocation(
                    requestID: bundle, name: "necto.device.probe.echo", version: 1, kind: .once, input: ["app": .string(bundle)]
                )), to: app.target)
                let result = try await nextEnvelope(events.stream).decode(NectoPluginResult.self)
                #expect(result.output == ["app": .string(bundle)])
                #expect(calls.withValue { $0 } == 1)
            } else {
                #expect(bundle == "com.example.shared.unregistered")
                #expect(calls.withValue { $0 } == 0)
            }
        }
        #expect(await center.connectedApps.map(\.appBundleID).sorted() == bundles)
        #expect(await center.unauthorizedApps.map(\.appBundleID) == ["com.example.shared.unregistered"])
        #expect(await center.unauthorizedApps.first?.reason == .missingKey)
        await center.stop()
        for worker in workers { await worker.value }
        for reader in readers { await reader.value }
    }

    @Test("one device can run protected and unprotected apps with independent authorization")
    func mixedAppsOnOneDevice() async throws {
        let fixture = try CredentialFixture()
        let credential = SecurityLocked<NectoTLSIdentity?>(nil)
        let lookups = SecurityLocked<[String]>([])
        let center = securityCenter { bundle in
            lookups.withValue { $0.append(bundle) }
            return credential.withValue { $0 }
        }
        let protected = NectoSDKRuntime(hello: { securityHello })
        let plain = NectoSDKRuntime(hello: {
            NectoHandshakeHello(appBundleID: "com.example.unprotected", appName: "Unprotected",
                deviceName: "Test iPhone", sdkVersion: "1", simulatorID: securityHello.simulatorID)
        })
        defer { protected.stop(); plain.stop() }
        let pin = try NectoPublicKeyPin(fixture.identity.publicKey)
        let deniedPair = try rawSessions()
        let deniedWorker = Task { await protected.accept(session: deniedPair.device, publicKey: pin) }
        #expect(try await admit(center, deniedPair.host) == nil)
        await deniedWorker.value

        let plainPair = try rawSessions()
        let plainWorker = Task { await plain.accept(session: plainPair.device) }
        let plainReader = try #require(try await center.accept(session: plainPair.host,
            deviceID: "simulator", connection: .simulator, usbDeviceID: nil, localPort: 12346))
        #expect(await center.connectedApps.map(\.appBundleID) == ["com.example.unprotected"])
        #expect(await center.unauthorizedApps.map(\.appBundleID) == [CredentialFixture.bundleID])
        #expect(lookups.withValue { $0 } == [CredentialFixture.bundleID])

        credential.withValue { $0 = fixture.identity }
        let securedPair = try rawSessions()
        let securedWorker = Task { await protected.accept(session: securedPair.device, publicKey: pin) }
        let securedReader = try #require(try await admit(center, securedPair.host))
        #expect(await center.connectedApps.count == 2)
        #expect(await center.unauthorizedApps.isEmpty)
        #expect(lookups.withValue { $0 } == [CredentialFixture.bundleID, CredentialFixture.bundleID])
        await center.stop()
        await plainWorker.value
        await securedWorker.value
        await plainReader.value
        await securedReader.value
    }

    @Test("the same bundle on two devices reuses the credential and authenticates each session")
    func sameBundleOnTwoDevices() async throws {
        let fixture = try CredentialFixture()
        let lookups = SecurityLocked<[String]>([])
        let center = securityCenter { bundle in
            lookups.withValue { $0.append(bundle) }
            return try fixture.store.identity(bundleID: bundle)
        }
        let pin = try NectoPublicKeyPin(fixture.identity.publicKey)
        var workers: [Task<Void, Never>] = []
        var readers: [Task<Void, Never>] = []
        var runtimes: [NectoSDKRuntime] = []
        for index in 0..<2 {
            let sdk = NectoSDKRuntime(hello: {
                NectoHandshakeHello(appBundleID: CredentialFixture.bundleID, appName: "Protected",
                    deviceName: "Phone \(index)", sdkVersion: "1", simulatorID: "sim-\(index)")
            })
            runtimes.append(sdk)
            let pair = try rawSessions()
            workers.append(Task { await sdk.accept(session: pair.device, publicKey: pin) })
            readers.append(try #require(try await center.accept(session: pair.host,
                deviceID: "simulator", connection: .simulator, usbDeviceID: nil, localPort: UInt16(12345 + index))))
        }
        #expect(await center.connectedApps.map(\.target.deviceID).sorted() == ["sim-0", "sim-1"])
        #expect(lookups.withValue { $0 } == [CredentialFixture.bundleID, CredentialFixture.bundleID])
        await center.stop()
        for worker in workers { await worker.value }
        for reader in readers { await reader.value }
        runtimes.forEach { $0.stop() }
    }

    @Test("the SDK and host upgrade their existing socket and exchange plugin messages", arguments: [false, true])
    func productionConnection(tcp: Bool) async throws {
        let fixture = try CredentialFixture()
        let calls = SecurityLocked(0)
        let sdk = NectoSDKRuntime(hello: { securityHello })
        #expect(sdk.register(ProbePlugin(calls: calls)))
        let center = securityCenter { bundle in try fixture.store.identity(bundleID: bundle) }
        let events = AsyncStream<NectoEnvelope>.makeStream()
        await center.onMessage { envelope, _ in events.continuation.yield(envelope) }
        let raw = try rawSessions(tcp: tcp)
        defer { raw.device.close(); raw.host.close(); sdk.stop() }
        let pin = try NectoPublicKeyPin(fixture.identity.publicKey)
        let worker = Task { await sdk.accept(session: raw.device, publicKey: pin) }
        let reader = try #require(try await admit(center, raw.host))
        #expect(try await nextEnvelope(events.stream).type == .pluginRegister)
        let app = try #require(await center.connectedApps.first)
        #expect(app.appBundleID == CredentialFixture.bundleID)
        #expect(await center.unauthorizedApps.isEmpty)
        try await center.send(NectoEnvelope(type: .pluginInvoke, encoding: NectoPluginInvocation(
            requestID: "secure", name: "necto.device.probe.echo", version: 1, kind: .once, input: ["secret": "value"]
        )), to: app.target)
        let result = try await nextEnvelope(events.stream).decode(NectoPluginResult.self)
        #expect(result.output == ["secret": "value"])
        #expect(calls.withValue { $0 } == 1)
        await center.stop()
        await worker.value
        await reader.value
    }

    @Test("missing, wrong, and unreadable keys deny a real session before plugin registration", arguments: [0, 1, 2])
    func deniedSession(mode: Int) async throws {
        let fixture = try CredentialFixture()
        let wrong = try CredentialFixture()
        let calls = SecurityLocked(0)
        let received = SecurityLocked(0)
        let sdk = NectoSDKRuntime(hello: { securityHello })
        #expect(sdk.register(ProbePlugin(calls: calls)))
        let center = securityCenter { _ in
            if mode == 2 { throw NectoSecurityError.keychain(-1) }
            return mode == 0 ? nil : wrong.identity
        }
        await center.onMessage { _, _ in received.withValue { $0 += 1 } }
        let raw = try rawSessions()
        defer { raw.device.close(); raw.host.close(); sdk.stop() }
        let pin = try NectoPublicKeyPin(fixture.identity.publicKey)
        let worker = Task { await sdk.accept(session: raw.device, publicKey: pin) }
        #expect(try await admit(center, raw.host) == nil)
        await worker.value
        #expect(await center.connectedApps.isEmpty)
        let app = try #require(await center.unauthorizedApps.first)
        #expect(app.reason == [.missingKey, .rejectedKey, .credentialUnavailable][mode])
        #expect(calls.withValue { $0 } == 0)
        #expect(received.withValue { $0 } == 0)
        await #expect(throws: NectoBridgeError(code: .unauthorized, message: "Authentication is required for '\(app.appBundleID)'.")) {
            try await center.send(NectoEnvelope(type: .pluginCancel, encoding: NectoJSONValue.null), to: app.target)
        }
        await center.stop()
        #expect(await center.unauthorizedApps.isEmpty)
    }

    @Test("installing a key recovers a denied app without restarting the SDK or host")
    func recover() async throws {
        let fixture = try CredentialFixture()
        let credential = SecurityLocked<NectoTLSIdentity?>(nil)
        let center = securityCenter { _ in credential.withValue { $0 } }
        let sdk = NectoSDKRuntime(hello: { securityHello })
        defer { sdk.stop() }
        let pin = try NectoPublicKeyPin(fixture.identity.publicKey)
        let first = try rawSessions()
        let failed = Task { await sdk.accept(session: first.device, publicKey: pin) }
        #expect(try await admit(center, first.host) == nil)
        await failed.value
        #expect(await center.unauthorizedApps.count == 1)
        credential.withValue { $0 = fixture.identity }
        let second = try rawSessions()
        let succeeded = Task { await sdk.accept(session: second.device, publicKey: pin) }
        let reader = try #require(try await admit(center, second.host))
        #expect(await center.connectedApps.count == 1)
        #expect(await center.unauthorizedApps.isEmpty)
        await center.stop()
        await succeeded.value
        await reader.value
    }

    @Test("a plaintext imitation cannot invoke a protected SDK or replace its authenticated session")
    func plaintextImitation() async throws {
        let fixture = try CredentialFixture()
        let sdk = NectoSDKRuntime(hello: { securityHello })
        let calls = SecurityLocked(0)
        #expect(sdk.register(ProbePlugin(calls: calls)))
        let pin = try NectoPublicKeyPin(fixture.identity.publicKey)
        let original = try rawSessions()
        let originalWorker = Task { await sdk.accept(session: original.device, publicKey: pin) }
        _ = try await original.host.receive(NectoSecurityOffer.self)
        let trusted = try await original.host.upgradingTLS(.host(fixture.identity))
        defer { trusted.close(); sdk.stop() }
        try await acceptSDKHello(trusted)

        let attacker = try rawSessions()
        defer { attacker.host.close() }
        let attackWorker = Task { await sdk.accept(session: attacker.device, publicKey: pin) }
        let offer = try await attacker.host.receive(NectoSecurityOffer.self)
        #expect(offer.appBundleID == CredentialFixture.bundleID)
        // An old host's acknowledgement is not TLS and cannot enable plugin dispatch.
        try? await attacker.host.send(NectoHandshakeAck(accepted: true))
        try? await attacker.host.send(NectoEnvelope(type: .pluginInvoke, encoding: NectoPluginInvocation(
            requestID: "attack", name: "necto.device.probe.echo", version: 1, kind: .once, input: [:]
        )))
        await attackWorker.value
        #expect(calls.withValue { $0 } == 0)
        try await invokeProbe(trusted)
        #expect(calls.withValue { $0 } == 1)
        trusted.close()
        await originalWorker.value
    }

    @Test("an unconfigured SDK never queries host credentials and keeps legacy framing")
    func legacyConnection() async throws {
        let center = securityCenter { _ in Issue.record("Legacy connection read the Keychain"); return nil }
        let sdk = NectoSDKRuntime(hello: { securityHello })
        let raw = try rawSessions()
        let worker = Task { await sdk.accept(session: raw.device) }
        let reader = try #require(try await admit(center, raw.host))
        #expect(await center.connectedApps.count == 1)
        #expect(await center.unauthorizedApps.isEmpty)
        await center.stop()
        await worker.value
        await reader.value
        sdk.stop()
    }

    @Test("invalid SDK configuration stops an existing listener rather than disabling protection", arguments: ["", "bad-key"])
    func invalidConfiguration(key: String) async throws {
        let sdk = NectoSDKRuntime(hello: { securityHello })
        sdk.start(port: 0)
        sdk.start(port: 0, publicKey: key)
        guard case .failed = sdk.status else { Issue.record("Invalid pin did not fail startup"); sdk.stop(); return }
        sdk.stop()
        #expect(sdk.status == .stopped)
    }

    @Test("a stopped center cannot publish an authentication attempt that completes later")
    func stopDuringLookup() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let center = securityCenter { _ in
            entered.continuation.yield(())
            for await _ in release.stream {}
            return nil
        }
        let raw = try rawSessions()
        defer { raw.device.close(); raw.host.close() }
        let accepting = Task { try await admit(center, raw.host) }
        try await raw.device.send(NectoSecurityOffer(hello: securityHello))
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        await center.stop()
        release.continuation.finish()
        await #expect(throws: CancellationError.self) { try await accepting.value }
        #expect(await center.unauthorizedApps.isEmpty)
        #expect(await center.connectedApps.isEmpty)
    }

    @Test("a malformed security offer is not admitted as a legacy app", arguments: [
        "{\"type\":\"necto.security\",\"version\":99}", "{\"type\":\"unknown\"}", "{}"
    ])
    func malformedOffer(json: String) async throws {
        let center = securityCenter { _ in Issue.record("Malformed offer queried credentials"); return nil }
        let raw = try rawSessions()
        defer { raw.device.close(); raw.host.close() }
        try await raw.device.send(Data(json.utf8))
        await #expect(throws: (any Error).self) { try await admit(center, raw.host) }
        #expect(await center.connectedApps.isEmpty)
        #expect(await center.unauthorizedApps.isEmpty)
    }
}
