//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing

@testable import NectoMacService

@Suite("Registry event recording")
struct NectoEventRegistryTests {
    @Test("registered app plugins record without a panel, version or surface channel")
    func appUsageWithoutPanel() async throws {
        let fixture = try await EventRegistryFixture.make()
        let target = NectoTarget(deviceID: "device", appBundleID: "com.example.app")
        await fixture.registry.setDeviceProviders([], for: target, pluginID: "app-logger", isRegistered: true)
        let params: NectoJSONValue = ["pluginId": "spoofed", "channel": "web", "count": 2]
        try await fixture.registry.recordDeviceEvent(
            NectoPluginEvent(pluginID: "app-logger", channel: "necto.usage",
                             payload: ["eventName": "app.started", "params": params]),
            from: target
        )

        let event = try #require(fixture.receiver.events.first)
        #expect(event.source == .device(id: "app-logger", version: nil))
        #expect(event.input.eventName == "app.started")
        #expect(event.jsonValue["origin"] == "device")
        #expect(event.jsonValue["pluginId"] == "app-logger")
        #expect(event.jsonValue["pluginVersion"] == nil)
        #expect(event.jsonValue["channel"] == nil)
        #expect(event.jsonValue["params"] == params)
        #expect(event.installationID == "host-installation")
        #expect(event.occurredAt == Date(timeIntervalSince1970: 123))
    }

    @Test("app usage exports the channel from invocation metadata", arguments: [NectoInvocationChannel.web, .cli])
    func appUsageWithInvocationChannel(channel: NectoInvocationChannel) async throws {
        let fixture = try await EventRegistryFixture.make()
        let target = NectoTarget(deviceID: "device", appBundleID: "com.example.app")
        await fixture.registry.setDeviceProviders([], for: target, pluginID: "app-logger", isRegistered: true)
        try await fixture.registry.recordDeviceEvent(
            NectoPluginEvent(
                pluginID: "app-logger", channel: "necto.usage", payload: eventInput, invocationChannel: channel
            ),
            from: target
        )

        let event = try #require(fixture.receiver.events.first)
        #expect(event.channel == channel)
        #expect(event.jsonValue["channel"] == .string(channel.rawValue))
    }

    @Test("app usage derives versions only from its own target's carried manifest")
    func appUsageVersionsStayTargetScoped() async throws {
        let fixture = try await EventRegistryFixture.make()
        let first = NectoTarget(deviceID: "shared-device", appBundleID: "com.example.first")
        let second = NectoTarget(deviceID: "shared-device", appBundleID: "com.example.second")
        let third = NectoTarget(deviceID: "other-device", appBundleID: "com.example.first")
        try await fixture.registry.install(manifest: eventManifest(version: "9.0.0"), sourceIdentity: "desktop")
        try await fixture.registry.installDevice(
            manifest: eventManifest(version: "1.0.0"), sourceIdentity: "first", for: first
        )
        try await fixture.registry.installDevice(
            manifest: eventManifest(version: "2.0.0"), sourceIdentity: "second", for: second
        )
        for target in [first, second, third] {
            await fixture.registry.setDeviceProviders([], for: target, pluginID: "event-source", isRegistered: true)
            try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: target)
        }
        #expect(fixture.receiver.events.map(\.source) == [
            .device(id: "event-source", version: "1.0.0"),
            .device(id: "event-source", version: "2.0.0"),
            .device(id: "event-source", version: nil),
        ])
        await fixture.registry.uninstallDevice(pluginID: "event-source", for: first)
        try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: first)
        #expect(fixture.receiver.events.last?.source == .device(id: "event-source", version: nil))
    }

    @Test("desktop and panel installations cannot stand in for app registration")
    func appUsageRequiresExactRegistration() async throws {
        let fixture = try await EventRegistryFixture.make()
        let target = NectoTarget(deviceID: "device", appBundleID: "com.example.app")
        let other = NectoTarget(deviceID: "other", appBundleID: "com.example.app")
        try await fixture.registry.install(manifest: eventManifest(), sourceIdentity: "desktop")
        try await fixture.registry.installDevice(manifest: eventManifest(), sourceIdentity: "device", for: target)
        await fixture.registry.setDeviceProviders([], for: other, pluginID: "event-source", isRegistered: true)
        await expectEventError(.operationNotFound) {
            try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: target)
        }
        await expectEventError(.operationNotFound) {
            try await fixture.registry.recordDeviceEvent(appUsageEvent(pluginID: "unknown"), from: other)
        }
        #expect(fixture.receiver.events.isEmpty)
    }

    @Test("app usage rejects malformed payloads and caller-supplied envelope metadata")
    func appUsageValidatesCommonInput() async throws {
        let fixture = try await EventRegistryFixture.make()
        let target = NectoTarget(deviceID: "device", appBundleID: "com.example.app")
        await fixture.registry.setDeviceProviders([], for: target, pluginID: "event-source", isRegistered: true)
        var invalid: [NectoJSONValue] = [
            .null, ["eventName": ""], ["eventName": "  "], ["eventName": 1],
            ["eventName": "app.started", "params": [1]],
            ["eventName": "app.started", "params": ["value": .number(.infinity)]],
        ]
        for field in ["eventId", "occurredAt", "installationId", "nectoVersion", "origin",
                      "pluginId", "pluginVersion", "relatedPluginId", "source", "channel", "invocationChannel"] {
            invalid.append(.object(["eventName": "app.started", field: "spoofed"]))
        }
        for payload in invalid {
            await expectEventError(.invalidInput) {
                try await fixture.registry.recordDeviceEvent(appUsageEvent(payload: payload), from: target)
            }
        }
        #expect(fixture.receiver.events.isEmpty)
    }

    @Test("app registration removal and disconnect stop usage until re-registration")
    func appUsageRegistrationLifecycle() async throws {
        let fixture = try await EventRegistryFixture.make()
        let target = NectoTarget(deviceID: "device", appBundleID: "com.example.app")
        await fixture.registry.setDeviceProviders([], for: target, pluginID: "event-source", isRegistered: true)
        try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: target)
        // An explicit removal wins even if stale providers accompany it.
        await fixture.registry.setDeviceProviders(
            [EventFixtureProvider()], for: target, pluginID: "event-source", isRegistered: false
        )
        await expectEventError(.operationNotFound) {
            try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: target)
        }
        await fixture.registry.setDeviceProviders([], for: target, pluginID: "event-source", isRegistered: true)
        await fixture.registry.unregisterDeviceProviders(for: target)
        await expectEventError(.operationNotFound) {
            try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: target)
        }
        await fixture.registry.setDeviceProviders([], for: target, pluginID: "event-source", isRegistered: true)
        try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: target)
        #expect(fixture.receiver.events.count == 2)
    }

    @Test("legacy provider registration retains nonempty catalogs and removes empty catalogs")
    func appUsageLegacyRegistration() async throws {
        let fixture = try await EventRegistryFixture.make()
        let target = NectoTarget(deviceID: "device", appBundleID: "com.example.app")
        await fixture.registry.setDeviceProviders([EventFixtureProvider()], for: target, pluginID: "event-source")
        try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: target)
        await fixture.registry.setDeviceProviders([], for: target, pluginID: "event-source")
        await expectEventError(.operationNotFound) {
            try await fixture.registry.recordDeviceEvent(appUsageEvent(), from: target)
        }
        #expect(fixture.receiver.events.count == 1)
    }

    @Test("app usage honors current exclusions and never buffers without a receiver")
    func appUsagePolicyAndReceiver() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "host", nectoVersion: "1.0.0")
        let registry = NectoPluginRegistry(eventDispatcher: dispatcher)
        let receiver = EventRegistryReceiver()
        let target = NectoTarget(deviceID: "device", appBundleID: "com.example.app")
        await registry.setDeviceProviders([], for: target, pluginID: "event-source", isRegistered: true)
        try await registry.recordDeviceEvent(appUsageEvent(), from: target)
        try await dispatcher.registerExporter { receiver.append($0) }
        #expect(receiver.events.isEmpty)
        await dispatcher.updatePolicy(.init(excludedPluginIDs: ["event-source"]))
        try await registry.recordDeviceEvent(appUsageEvent(), from: target)
        #expect(receiver.events.isEmpty)
        await dispatcher.updatePolicy(.init())
        #expect(receiver.events.isEmpty)
        try await registry.recordDeviceEvent(appUsageEvent(), from: target)
        #expect(receiver.events.count == 1)
    }

    @Test("app usage without a dispatcher still validates its payload")
    func appUsageNoDispatcher() async throws {
        let registry = NectoPluginRegistry()
        let target = NectoTarget(deviceID: "device", appBundleID: "com.example.app")
        await registry.setDeviceProviders([], for: target, pluginID: "event-source", isRegistered: true)
        try await registry.recordDeviceEvent(appUsageEvent(), from: target)
        await expectEventError(.invalidInput) {
            try await registry.recordDeviceEvent(appUsageEvent(payload: ["eventName": ""]), from: target)
        }
    }

    @Test("desktop events retain their origin even with a selected device target")
    func desktopMetadata() async throws {
        let fixture = try await EventRegistryFixture.make()
        let plugin = try await fixture.registry.install(
            manifest: eventManifest(version: "2.3.4"), sourceIdentity: "installation:desktop"
        )

        try await fixture.registry.recordEvent(
            pluginID: plugin.manifest.id, input: eventInput, target: nil,
            expectedPrincipal: plugin.principal, channel: .web
        )

        try await fixture.registry.recordEvent(
            pluginID: plugin.manifest.id, input: eventInput,
            target: NectoTarget(deviceID: "selected-device", appBundleID: "com.example.selected"),
            expectedPrincipal: plugin.principal, channel: .web
        )
        let event = try #require(fixture.receiver.events.first)
        #expect(fixture.receiver.events.count == 2)
        #expect(fixture.receiver.events.allSatisfy { $0.jsonValue["origin"] == "desktop" })
        #expect(event.source == .desktop(id: plugin.manifest.id, version: "2.3.4"))
        #expect(event.channel == .web)
        #expect(event.input.eventName == "records.opened")
        #expect(event.jsonValue["kind"] == nil)
    }

    @Test("device scopes retain their own manifest version and channel")
    func deviceMetadata() async throws {
        let fixture = try await EventRegistryFixture.make()
        let first = NectoTarget(deviceID: "device-one", appBundleID: "com.example.first")
        let second = NectoTarget(deviceID: "device-two", appBundleID: "com.example.second")
        let firstPlugin = try await fixture.registry.installDevice(
            manifest: eventManifest(version: "1.0.0"), sourceIdentity: "device:com.example.first", for: first
        )
        let secondPlugin = try await fixture.registry.installDevice(
            manifest: eventManifest(version: "3.0.0"), sourceIdentity: "device:com.example.second", for: second
        )

        try await fixture.registry.recordEvent(
            pluginID: firstPlugin.manifest.id, input: eventInput, target: first,
            expectedPrincipal: firstPlugin.principal, channel: .cli
        )
        try await fixture.registry.recordEvent(
            pluginID: secondPlugin.manifest.id, input: eventInput, target: second,
            expectedPrincipal: secondPlugin.principal
        )

        let events = fixture.receiver.events
        #expect(events.count == 2)
        #expect(events.map(\.source) == [
            .device(id: "event-source", version: "1.0.0"),
            .device(id: "event-source", version: "3.0.0"),
        ])
        #expect(events.map(\.channel) == [.cli, nil])
        #expect(events.allSatisfy { $0.jsonValue["origin"] == "device" })
    }

    @Test("wrong principals, removed installations and stale principals cannot record")
    func rejectsInvalidCallers() async throws {
        let fixture = try await EventRegistryFixture.make()
        let original = try await fixture.registry.install(
            manifest: eventManifest(), sourceIdentity: "installation:original"
        )
        let wrong = NectoPluginPrincipal(pluginID: "another-plugin", sourceIdentity: "installation:original")
        await expectEventError(.permissionDenied) {
            try await fixture.registry.recordEvent(
                pluginID: original.manifest.id, input: eventInput, target: nil, expectedPrincipal: wrong
            )
        }
        await fixture.registry.uninstall(pluginID: original.manifest.id)
        await expectEventError(.operationNotFound) {
            try await fixture.registry.recordEvent(
                pluginID: original.manifest.id, input: eventInput, target: nil,
                expectedPrincipal: original.principal
            )
        }
        let replacement = try await fixture.registry.install(
            manifest: eventManifest(version: "2.0.0"), sourceIdentity: "installation:replacement"
        )
        await expectEventError(.permissionDenied) {
            try await fixture.registry.recordEvent(
                pluginID: replacement.manifest.id, input: eventInput, target: nil,
                expectedPrincipal: original.principal
            )
        }
        #expect(fixture.receiver.events.isEmpty)

        try await fixture.registry.recordEvent(
            pluginID: replacement.manifest.id, input: eventInput, target: nil,
            expectedPrincipal: replacement.principal
        )
        #expect(fixture.receiver.events.count == 1)
    }

    @Test("host metadata cannot be supplied in the event envelope")
    func rejectsSpoofedEnvelope() async throws {
        let fixture = try await EventRegistryFixture.make()
        let plugin = try await fixture.registry.install(
            manifest: eventManifest(), sourceIdentity: "installation:source"
        )
        for field in [
            "eventId", "occurredAt", "installationId", "nectoVersion", "origin",
            "pluginId", "pluginVersion", "relatedPluginId", "source", "channel",
        ] {
            var fields = try #require(eventInput.objectValue)
            fields[field] = "spoofed"
            let input = NectoJSONValue.object(fields)
            await expectEventError(.invalidInput) {
                try await fixture.registry.recordEvent(
                    pluginID: plugin.manifest.id, input: input, target: nil,
                    expectedPrincipal: plugin.principal
                )
            }
        }
        #expect(fixture.receiver.events.isEmpty)
    }

    @Test("similarly named parameters remain data and cannot replace host metadata")
    func parametersDoNotOverwriteMetadata() async throws {
        let fixture = try await EventRegistryFixture.make()
        let plugin = try await fixture.registry.install(
            manifest: eventManifest(version: "4.0.0"), sourceIdentity: "installation:source"
        )
        let params: NectoJSONValue = [
            "eventId": "custom-id", "occurredAt": 0, "installationId": "custom-installation",
            "nectoVersion": "custom-version", "origin": "necto", "pluginId": "another-plugin",
            "pluginVersion": "custom-plugin-version", "channel": "cli",
        ]
        try await fixture.registry.recordEvent(
            pluginID: plugin.manifest.id,
            input: ["eventName": "records.opened", "params": params],
            target: nil, expectedPrincipal: plugin.principal, channel: .web
        )

        let event = try #require(fixture.receiver.events.first)
        #expect(event.source == .desktop(id: "event-source", version: "4.0.0"))
        #expect(event.channel == .web)
        #expect(event.installationID == "host-installation")
        #expect(event.nectoVersion == "1.2.3")
        #expect(event.occurredAt == Date(timeIntervalSince1970: 123))
        let fields = try #require(event.jsonValue.objectValue)
        #expect(fields["eventId"] == .string(event.eventID.uuidString))
        #expect(fields["pluginId"] == "event-source")
        #expect(fields["pluginVersion"] == "4.0.0")
        #expect(fields["origin"] == "desktop")
        #expect(fields["params"] == params)
    }

    @Test("a registry without a dispatcher accepts valid events and still validates input")
    func noDispatcher() async throws {
        let registry = NectoPluginRegistry()
        let plugin = try await registry.install(manifest: eventManifest(), sourceIdentity: "installation:source")
        try await registry.recordEvent(
            pluginID: plugin.manifest.id, input: eventInput, target: nil, expectedPrincipal: plugin.principal
        )
        await expectEventError(.invalidInput) {
            try await registry.recordEvent(
                pluginID: plugin.manifest.id, input: ["eventName": ""],
                target: nil, expectedPrincipal: plugin.principal
            )
        }
    }

    @Test("ordinary provider calls do not generate usage events")
    func ordinaryInvocationDoesNotRecord() async throws {
        let fixture = try await EventRegistryFixture.make()
        let plugin = try await fixture.registry.install(
            manifest: eventManifest(), sourceIdentity: "installation:source"
        )
        await fixture.registry.registerHostProvider(EventFixtureProvider())
        let output = try await fixture.registry.invoke(
            pluginID: plugin.manifest.id, operationID: "records.list", target: nil,
            expectedPrincipal: plugin.principal
        )
        #expect(output == ["ok": true])
        #expect(fixture.receiver.events.isEmpty)
    }
}

private let eventInput: NectoJSONValue = ["eventName": "records.opened"]

private func appUsageEvent(
    pluginID: String = "event-source", payload: NectoJSONValue = eventInput
) -> NectoPluginEvent {
    NectoPluginEvent(pluginID: pluginID, channel: "necto.usage", payload: payload)
}
private let eventBinding = NectoBridgeBinding(name: "necto.desktop.records.list", version: 1)

private func eventManifest(version: String = "1.0.0") -> NectoPluginManifest {
    NectoPluginManifest(
        id: "event-source", name: "Event Source", description: "A recording fixture",
        version: version, author: "Necto", icon: .init(systemName: "list.bullet"),
        assets: ["index.html"], allowedOrigins: ["self"],
        operations: [NectoOperation(
            id: "records.list", title: "List", description: "List records", kind: .once,
            binding: eventBinding, inputSchema: ["type": "object"], outputSchema: ["type": "object"],
            timeoutMs: 1000
        )]
    )
}

private struct EventFixtureProvider: NectoOperationProvider {
    let descriptor = NectoBridgeDescriptor(binding: eventBinding, kind: .once)

    func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        ["ok": true]
    }
}

private struct EventRegistryFixture {
    let registry: NectoPluginRegistry
    let receiver: EventRegistryReceiver

    static func make() async throws -> Self {
        let dispatcher = NectoEventDispatcher(
            installationID: "host-installation", nectoVersion: "1.2.3",
            now: { Date(timeIntervalSince1970: 123) }
        )
        let receiver = EventRegistryReceiver()
        try await dispatcher.registerExporter { receiver.append($0) }
        return Self(registry: NectoPluginRegistry(eventDispatcher: dispatcher), receiver: receiver)
    }
}

private final class EventRegistryReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NectoEvent] = []

    var events: [NectoEvent] { lock.withLock { storage } }

    func append(_ event: NectoEvent) {
        lock.withLock { storage.append(event) }
    }
}

private func expectEventError(
    _ code: NectoBridgeErrorCode,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected bridge error \(code.rawValue)")
    } catch let error as NectoBridgeError {
        #expect(error.code == code)
    } catch {
        Issue.record("Expected a bridge error, received \(error)")
    }
}
