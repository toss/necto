//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing
@testable import NectoMacService

private struct ScopeProvider: NectoOperationProvider {
    let descriptor: NectoBridgeDescriptor
    func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        ["source": .string(context.principal.sourceIdentity),
         "device": context.target.map { .string($0.deviceID) } ?? .null,
         "app": context.target.map { .string($0.appBundleID) } ?? .null]
    }
    func subscribe(input: NectoJSONValue, context: NectoInvocationContext) async throws -> AsyncThrowingStream<NectoJSONValue, any Error> {
        let value = try await invoke(input: input, context: context)
        return AsyncThrowingStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }
}

private func scopeManifest(version: String) -> NectoPluginManifest {
    NectoPluginManifest(id: "shared", name: "Shared", description: "Scoped fixture", version: version,
        author: "Necto", icon: .init(systemName: "network"), assets: ["index.html"], allowedOrigins: ["self"],
        operations: [NectoOperation(id: "read", title: "Read", description: "Read selected owner", kind: .once,
            binding: .init(name: "necto.desktop.scope.read", version: 1),
            inputSchema: ["type": "object", "additionalProperties": false], outputSchema: ["type": "object"], timeoutMs: 1000),
        NectoOperation(id: "observe", title: "Observe", description: "Observe selected owner", kind: .stream,
            binding: .init(name: "necto.desktop.scope.observe", version: 1),
            inputSchema: ["type": "object"], outputSchema: ["type": "object"], timeoutMs: 1000)])
}

private func connected(_ target: NectoTarget) -> NectoConnectedApp {
    NectoConnectedApp(target: target, deviceName: target.deviceID, appName: target.appBundleID,
        sdkVersion: "1", connection: .simulator)
}

@Suite("Control bridge ownership", .timeLimit(.minutes(1)))
struct NectoControlBridgeTests {
    @Test("unauthorized targets stay discoverable but cannot list, invoke, or subscribe to plugins")
    func unauthorizedTarget() async throws {
        let target = NectoTarget(deviceID: "phone", appBundleID: "protected.app")
        let denied = NectoUnauthorizedApp(target: target, appName: "Protected", deviceName: "Phone",
            osVersion: "26", connection: .usb, reason: .missingKey)
        let registry = NectoPluginRegistry()
        let bridge = NectoControlBridge(registry: registry, connectedApps: { [] }, unauthorizedApps: { [denied] })
        let info = await bridge.targets()
        #expect(info["targets"]?.arrayValue?.first?["status"] == "unauthorized")
        #expect(info["targets"]?.arrayValue?.first?["reason"] == "missingKey")
        for kind in 0..<4 {
            do {
                switch kind {
                case 0: _ = try await bridge.plugins(app: target.appBundleID, device: target.deviceID, desktop: false)
                case 1: _ = try await bridge.plugins(app: target.appBundleID, device: target.deviceID, desktop: false, pluginID: "shared")
                case 2: _ = try await bridge.invoke(pluginID: "shared", operationID: "read", input: [:],
                    app: target.appBundleID, device: target.deviceID, desktop: false)
                default: try await bridge.subscribe(pluginID: "shared", operationID: "observe", input: [:],
                    app: target.appBundleID, device: target.deviceID, desktop: false, onEvent: { _ in Issue.record("Unauthorized event") })
                }
                Issue.record("Unauthorized operation succeeded")
            } catch let error as NectoBridgeError { #expect(error.code == .unauthorized) }
        }
        try await registry.install(manifest: scopeManifest(version: "1.0.0"), sourceIdentity: "desktop")
        let desktop = try await bridge.plugins(app: nil, device: nil, desktop: true)
        #expect(desktop["plugins"]?.arrayValue?.count == 1)

        let recovered = NectoControlBridge(registry: registry, connectedApps: { [connected(target)] }, unauthorizedApps: { [denied] })
        let targets = await recovered.targets()["targets"]?.arrayValue
        #expect(targets?.count == 1)
        #expect(targets?.first?["status"] == "connected")
    }

    @Test func duplicateIDsStayScopedAcrossDiscoveryAndExecution() async throws {
        let registry = NectoPluginRegistry()
        let targets = [NectoTarget(deviceID: "one", appBundleID: "app.a"),
                       NectoTarget(deviceID: "one", appBundleID: "app.b"),
                       NectoTarget(deviceID: "two", appBundleID: "app.a")]
        try await registry.install(manifest: scopeManifest(version: "9.0.0"), sourceIdentity: "desktop")
        for (index, target) in targets.enumerated() {
            try await registry.installDevice(manifest: scopeManifest(version: "1.0.\(index)"),
                sourceIdentity: "owner-\(index)", for: target)
        }
        for (name, kind) in [("read", NectoOperationKind.once), ("observe", .stream)] {
            await registry.registerHostProvider(ScopeProvider(descriptor: .init(
                binding: .init(name: "necto.desktop.scope.\(name)", version: 1), kind: kind)))
        }
        let bridge = NectoControlBridge(registry: registry, connectedApps: { targets.map(connected) })
        for (index, target) in targets.enumerated() {
            let list = try await bridge.plugins(app: target.appBundleID, device: target.deviceID, desktop: false)
            #expect(list["plugins"]?.arrayValue?.first?["version"] == .string("1.0.\(index)"))
            let help = try await bridge.plugins(app: target.appBundleID, device: target.deviceID, desktop: false,
                pluginID: "shared", operationID: "read")
            #expect(help["plugin"]?["version"] == .string("1.0.\(index)"))
            #expect(help["operation"]?["available"] == true)
            #expect(help["operation"]?["inputSchema"]?["additionalProperties"] == false)
            let result = try await bridge.invoke(pluginID: "shared", operationID: "read", input: [:],
                app: target.appBundleID, device: target.deviceID, desktop: false)
            #expect(result["source"] == .string("owner-\(index)"))
            #expect(result["app"] == .string(target.appBundleID))
            #expect(result["device"] == .string(target.deviceID))
            await #expect(throws: NectoBridgeError.self) {
                try await bridge.invoke(pluginID: "shared", operationID: "read", input: ["unexpected": true],
                    app: target.appBundleID, device: target.deviceID, desktop: false)
            }
            let events = NSLockEvents()
            try await bridge.subscribe(pluginID: "shared", operationID: "observe", input: [:],
                app: target.appBundleID, device: target.deviceID, desktop: false, onEvent: { events.append($0) })
            #expect(events.values == [result])
        }
        let desktop = try await bridge.invoke(pluginID: "shared", operationID: "read", input: [:], app: nil, device: nil, desktop: true)
        #expect(desktop["source"] == "desktop")
        #expect(desktop["app"] == .null)
    }

    @Test func rejectsMissingContradictoryAndDisconnectedScopes() async throws {
        let target = NectoTarget(deviceID: "one", appBundleID: "app.a")
        let bridge = NectoControlBridge(registry: NectoPluginRegistry(), connectedApps: { [connected(target)] })
        for (app, device, desktop) in [(nil, nil, false), ("app.a", nil, false), (nil, "one", false), ("app.a", nil, true)] as [(String?, String?, Bool)] {
            await #expect(throws: NectoBridgeError.self) {
                try await bridge.plugins(app: app, device: device, desktop: desktop)
            }
        }
        await #expect(throws: NectoBridgeError.self) {
            try await bridge.plugins(app: "app.a", device: "gone", desktop: false)
        }
        await #expect(throws: NectoBridgeError.self) {
            try await bridge.plugins(app: "app.a", device: "one", desktop: false, operationID: "read")
        }
    }

    @Test func deviceScopeDoesNotFallBackToDesktopInstallation() async throws {
        let registry = NectoPluginRegistry()
        try await registry.install(manifest: scopeManifest(version: "1.0.0"), sourceIdentity: "desktop")
        let target = NectoTarget(deviceID: "one", appBundleID: "app.a")
        let bridge = NectoControlBridge(registry: registry, connectedApps: { [connected(target)] })
        #expect(try await bridge.plugins(app: "app.a", device: "one", desktop: false)["plugins"]?.arrayValue?.isEmpty == true)
        await #expect(throws: NectoBridgeError.self) {
            try await bridge.invoke(pluginID: "shared", operationID: "read", input: [:], app: "app.a", device: "one", desktop: false)
        }
        await #expect(throws: NectoBridgeError.self) {
            try await bridge.plugins(app: "app.a", device: "one", desktop: false, pluginID: "shared")
        }
        let offline = NectoControlBridge(registry: registry, connectedApps: { [] })
        #expect(try await offline.plugins(app: nil, device: nil, desktop: true)["plugins"]?.arrayValue?.count == 1)
        let help = try await offline.plugins(app: nil, device: nil, desktop: true, pluginID: "shared", operationID: "read")
        #expect(help["operation"]?["available"] == false)
    }

    @Test func disconnectRejectsPreviouslyValidTargetWithoutChangingDesktopScope() async throws {
        let registry = NectoPluginRegistry()
        let target = NectoTarget(deviceID: "one", appBundleID: "app.a")
        try await registry.installDevice(manifest: scopeManifest(version: "1.0.0"), sourceIdentity: "owner", for: target)
        let connections = ScopeConnections(apps: [connected(target)])
        let bridge = NectoControlBridge(registry: registry, connectedApps: { await connections.apps })
        #expect(try await bridge.plugins(app: "app.a", device: "one", desktop: false)["plugins"]?.arrayValue?.count == 1)
        await connections.disconnect()
        await #expect(throws: NectoBridgeError.self) {
            try await bridge.invoke(pluginID: "shared", operationID: "read", input: [:], app: "app.a", device: "one", desktop: false)
        }
        await #expect(throws: NectoBridgeError.self) {
            try await bridge.plugins(app: "app.a", device: "one", desktop: false, pluginID: "shared")
        }
    }

    @Test func cancellingBridgeSubscriptionTerminatesProviderStream() async throws {
        let registry = NectoPluginRegistry()
        try await registry.install(manifest: scopeManifest(version: "1.0.0"), sourceIdentity: "desktop")
        let pair = AsyncThrowingStream<NectoJSONValue, any Error>.makeStream()
        let ended = AsyncStream<Void>.makeStream()
        pair.continuation.onTermination = { _ in ended.continuation.yield(()); ended.continuation.finish() }
        await registry.registerHostProvider(ScopeLiveProvider(stream: pair.stream))
        let bridge = NectoControlBridge(registry: registry, connectedApps: { [] })
        let received = AsyncStream<Void>.makeStream()
        let subscription = Task {
            try await bridge.subscribe(pluginID: "shared", operationID: "observe", input: [:], app: nil, device: nil,
                desktop: true, onEvent: { _ in received.continuation.yield(()) })
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(3))
            received.continuation.finish()
            ended.continuation.finish()
        }
        defer { watchdog.cancel(); subscription.cancel(); pair.continuation.finish() }
        pair.continuation.yield([:])
        var ready = received.stream.makeAsyncIterator()
        #expect(await ready.next() != nil)
        subscription.cancel()
        var termination = ended.stream.makeAsyncIterator()
        #expect(await termination.next() != nil)
        _ = await subscription.result
    }
}

private struct ScopeLiveProvider: NectoOperationProvider {
    let descriptor = NectoBridgeDescriptor(binding: .init(name: "necto.desktop.scope.observe", version: 1), kind: .stream)
    let stream: AsyncThrowingStream<NectoJSONValue, any Error>
    func subscribe(input: NectoJSONValue, context: NectoInvocationContext) async throws -> AsyncThrowingStream<NectoJSONValue, any Error> { stream }
}

private actor ScopeConnections {
    var apps: [NectoConnectedApp]
    init(apps: [NectoConnectedApp]) { self.apps = apps }
    func disconnect() { apps = [] }
}

private final class NSLockEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NectoJSONValue] = []
    var values: [NectoJSONValue] { lock.withLock { storage } }
    func append(_ value: NectoJSONValue) { lock.withLock { storage.append(value) } }
}
