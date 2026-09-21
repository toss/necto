//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import NectoTransport
import Testing
@testable import NectoMacService

@MainActor
final class SecurityConnectionHost {
    let center: NectoConnectionCenter
    let bridge: NectoDeviceBridgeClient
    private(set) var plugins: [NectoTarget: Set<String>] = [:]
    private var messages: Task<Void, Never>?
    private var connections: Task<Void, Never>?
    private let envelopes = AsyncStream<(NectoEnvelope, NectoTarget)>.makeStream()

    init(identity: @escaping @Sendable (String) async throws -> NectoTLSIdentity?) {
        center = NectoConnectionCenter(
            port: NectoTransportDefaults.devicePort, probeInterval: .milliseconds(100),
            deviceEvents: { AsyncThrowingStream { $0.finish() } }, identity: identity
        )
        bridge = NectoDeviceBridgeClient(messenger: Messenger(center: center))
    }

    func start() async {
        await center.onMessage { [envelopes] envelope, target in
            guard target.appBundleID == AppFixture.exampleID else { return }
            envelopes.continuation.yield((envelope, target))
        }
        messages = Task {
            for await (envelope, target) in envelopes.stream {
                do {
                    switch envelope.type {
                    case .pluginRegister:
                        let registration = try envelope.decode(NectoPluginRegistration.self)
                        plugins[target, default: []].insert(registration.pluginID)
                    case .pluginResult:
                        await bridge.receive(try envelope.decode(NectoPluginResult.self))
                    default: break
                    }
                } catch { Issue.record(error) }
            }
        }
        connections = Task {
            var known: Set<NectoTarget> = []
            for await apps in await center.updates() {
                let current = Set(apps.map(\.target))
                for target in known.subtracting(current) {
                    plugins.removeValue(forKey: target)
                    await bridge.targetDisconnected(target)
                }
                known = current
            }
        }
        await center.start()
    }

    func stop() async {
        for app in await center.connectedApps { await bridge.targetDisconnected(app.target) }
        await center.stop()
        envelopes.continuation.finish()
        messages?.cancel()
        connections?.cancel()
        await messages?.value
        await connections?.value
    }

    func waitForPlugins(_ app: AppFixture) async throws -> NectoTarget {
        try await app.wait("SDK plugin registration") {
            self.plugins.contains { $0.key.appBundleID == AppFixture.exampleID && $0.value.isSuperset(of: ["preferences", "performance-monitor"]) }
        }
        return try #require(plugins.keys.first { $0.appBundleID == AppFixture.exampleID })
    }

    func invoke(_ operation: String, input: NectoJSONValue, target: NectoTarget) async throws -> NectoJSONValue {
        try await withThrowingTaskGroup(of: NectoJSONValue.self) { group in
            group.addTask { [bridge] in
                try await bridge.invoke(name: "necto.device." + operation, version: 1, kind: .once, input: input, target: target)
            }
            group.addTask { try await Task.sleep(for: .seconds(10)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct Messenger: NectoDeviceMessenger {
        let center: NectoConnectionCenter
        func send(_ envelope: NectoEnvelope, to target: NectoTarget) async throws {
            try await center.send(envelope, to: target)
        }
    }
}
