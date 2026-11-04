//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing

@testable import NectoMacService

@Suite("Registry event recording")
struct NectoEventRegistryTests {
    @Test("desktop events retain their origin even with a selected device target")
    func desktopMetadata() async throws {
        let fixture = try await EventRegistryFixture.make()
        let plugin = try await fixture.registry.install(
            manifest: eventManifest(version: "2.3.4"), sourceIdentity: "installation:desktop"
        )

        try await fixture.registry.recordEvent(
            pluginID: plugin.manifest.id, input: eventInput, target: nil,
            expectedPrincipal: plugin.principal, channel: .ui
        )

        try await fixture.registry.recordEvent(
            pluginID: plugin.manifest.id, input: eventInput,
            target: NectoTarget(deviceID: "selected-device", appBundleID: "com.example.selected"),
            expectedPrincipal: plugin.principal, channel: .ui
        )
        let event = try #require(fixture.receiver.events.first)
        #expect(fixture.receiver.events.count == 2)
        #expect(fixture.receiver.events.allSatisfy { $0.jsonValue["origin"] == "desktop" })
        #expect(event.source == .desktop(id: plugin.manifest.id, version: "2.3.4"))
        #expect(event.channel == .ui)
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
            target: nil, expectedPrincipal: plugin.principal, channel: .ui
        )

        let event = try #require(fixture.receiver.events.first)
        #expect(event.source == .desktop(id: "event-source", version: "4.0.0"))
        #expect(event.channel == .ui)
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
