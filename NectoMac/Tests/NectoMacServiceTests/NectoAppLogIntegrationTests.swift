//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import NectoTransport
import Testing

@testable import NectoMacService
@testable import NectoSDK

private final class AppLogIntegrationPlugin: NectoPlugin, @unchecked Sendable {
    let id = "com.example.app-log-integration"
    private let lock = NSLock()
    private var storedLogger: NectoPluginLogger?

    var logger: NectoPluginLogger? { lock.withLock { storedLogger } }

    func register(_ necto: NectoRegistrar) {
        lock.withLock { storedLogger = necto.logger }
    }
}

private final class AppLogIntegrationReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NectoEvent] = []

    var events: [NectoEvent] { lock.withLock { storage } }

    func append(_ event: NectoEvent) {
        lock.withLock { storage.append(event) }
    }
}

@Suite("App logger integration", .timeLimit(.minutes(1)))
struct NectoAppLogIntegrationTests {
    @Test("A logger-only SDK plugin reaches the exporter through the existing event transport and router")
    func loggerToExporter() async throws {
        let runtime = NectoSDKRuntime()
        let plugin = AppLogIntegrationPlugin()
        try #require(runtime.register(plugin))
        let logger = try #require(plugin.logger)
        let dispatcher = NectoEventDispatcher(installationID: "synthetic-installation", nectoVersion: "1.2.3")
        let registry = NectoPluginRegistry(eventDispatcher: dispatcher)
        let router = NectoPluginEventRouter()
        let receiver = AppLogIntegrationReceiver()
        try await dispatcher.registerExporter { receiver.append($0) }
        await router.on(channel: "necto.usage") { event, target in
            do {
                try await registry.recordDeviceEvent(event, from: target)
            } catch {
                Issue.record("An SDK usage event failed host validation: \(error)")
            }
        }
        let target = NectoTarget(deviceID: "synthetic-device", appBundleID: "com.example.logger")
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let app = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[0]))
        let host = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[1]))
        let worker = Task { await runtime.accept(session: app) }
        defer { host.close(); runtime.stop(); worker.cancel() }

        // Bound every socket read, including the real handshake and registration.
        try await host.handshake(timeout: .seconds(5)) {
            let hello = try await host.receive(NectoHandshakeHello.self)
            #expect(hello.protocolVersion == NectoProtocol.currentVersion)
            try await host.send(NectoHandshakeAck(accepted: true))
            let envelope = try await host.receive(NectoEnvelope.self)
            try #require(envelope.type == .pluginRegister)
            let registration = try envelope.decode(NectoPluginRegistration.self)
            #expect(registration.pluginID == plugin.id)
            #expect(registration.isActive)
            #expect(registration.catalog.bridges.isEmpty)
            #expect(registration.panel == nil)
            await registry.setDeviceProviders([], for: target, pluginID: registration.pluginID,
                                              isRegistered: registration.isActive)

            logger.log("callback.finished", params: ["count": 2, "nested": ["ok": true]])
            let loggedEnvelope = try await host.receive(NectoEnvelope.self)
            try #require(loggedEnvelope.type == .pluginEvent)
            let logged = try loggedEnvelope.decode(NectoPluginEvent.self)
            #expect(logged.pluginID == plugin.id)
            #expect(logged.channel == "necto.usage")
            await router.route(logged, from: target)

            let event = try #require(receiver.events.first)
            #expect(receiver.events.count == 1)
            #expect(event.source == .device(id: plugin.id, version: nil))
            #expect(event.input.eventName == "callback.finished")
            #expect(event.input.params == ["count": 2, "nested": ["ok": true]])
            #expect(event.channel == nil)
            #expect(event.jsonValue["origin"] == "device")
            #expect(event.jsonValue["pluginId"] == .string(plugin.id))
            #expect(event.jsonValue["pluginVersion"] == nil)
            #expect(event.jsonValue["channel"] == nil)
            #expect(event.installationID == "synthetic-installation")

            await dispatcher.updatePolicy(.init(excludedPluginIDs: [plugin.id]))
            logger.log("excluded")
            let excludedEnvelope = try await host.receive(NectoEnvelope.self)
            try #require(excludedEnvelope.type == .pluginEvent)
            await router.route(try excludedEnvelope.decode(NectoPluginEvent.self), from: target)
            #expect(receiver.events.count == 1)

            await dispatcher.updatePolicy(.init())
            logger.log("resumed")
            let resumedEnvelope = try await host.receive(NectoEnvelope.self)
            try #require(resumedEnvelope.type == .pluginEvent)
            await router.route(try resumedEnvelope.decode(NectoPluginEvent.self), from: target)
            #expect(receiver.events.map(\.input.eventName) == ["callback.finished", "resumed"])
        }
        host.close()
        await worker.value
    }
}
