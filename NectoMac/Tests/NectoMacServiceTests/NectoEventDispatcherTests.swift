//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing
@testable import NectoMacService

private final class EventReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [NectoEvent] = []

    func accept(_ event: NectoEvent) {
        lock.withLock { received.append(event) }
    }

    var events: [NectoEvent] { lock.withLock { received } }
}

private let recordingSource = NectoEvent.Source.desktop(id: "tools", version: "1.2.0")

private func eventInput(_ name: String = "rule.applied") throws -> NectoEvent.Input {
    try NectoEvent.Input(eventName: name)
}

@Suite("Event dispatcher")
struct NectoEventDispatcherTests {
    @Test("records carry common metadata and arbitrary JSON parameters")
    func enrichesEvents() async throws {
        let timestamp = Date(timeIntervalSince1970: 1234.5)
        let dispatcher = NectoEventDispatcher(
            installationID: "test-installation", nectoVersion: "1.0.0",
            now: { timestamp }
        )
        let receiver = EventReceiver()
        try await dispatcher.registerExporter(receive: receiver.accept)
        let params: [String: NectoJSONValue] = [
            "options": ["enabled": true, "items": [1, "two", .null]],
            "count": 3,
            "kind": "plugin-defined-category",
        ]
        let input = try NectoEvent.Input(eventName: "any.new.event", params: params)
        await dispatcher.record(input, source: recordingSource, channel: .cli)
        await dispatcher.record(input, source: recordingSource, channel: .ui)

        let events = receiver.events
        #expect(events.count == 2)
        let event = try #require(events.first)
        #expect(event.input.params == params)
        #expect(event.jsonValue["kind"] == nil)
        #expect(event.jsonValue["params"]?["kind"] == "plugin-defined-category")
        #expect(event.installationID == "test-installation")
        #expect(event.occurredAt == timestamp)
        #expect(event.source == recordingSource)
        #expect(event.jsonValue["origin"] == "desktop")
        #expect(event.channel == .cli)
        #expect(event.jsonValue["occurredAt"] == .number(1_234_500))
        #expect(event.jsonValue["pluginId"] == "tools")
        #expect(event.jsonValue["pluginVersion"] == "1.2.0")
        #expect(event.jsonValue["nectoVersion"] == "1.0.0")
        #expect(events.first?.eventID != events.last?.eventID)
        #expect(events.last?.channel == .ui)
        #expect(events.last?.installationID == event.installationID)
        _ = try event.jsonValue.jsonData()
    }

    @Test("registration starts delivery and rejects a second receiver")
    func registrationControlsDelivery() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "test-installation", nectoVersion: "1.0.0")
        let receiver = EventReceiver()
        await dispatcher.record(try eventInput("before.registration"), source: recordingSource)
        #expect(receiver.events.isEmpty)
        let registration = try await dispatcher.registerExporter(receive: receiver.accept)
        await dispatcher.record(try eventInput("after.registration"), source: recordingSource)
        #expect(receiver.events.map(\.input.eventName) == ["after.registration"])
        do {
            try await dispatcher.registerExporter(receive: receiver.accept)
            Issue.record("A duplicate exporter registration replaced the receiver")
        } catch let error as NectoBridgeError {
            #expect(error.code == .operationUnavailable)
        }
        await dispatcher.unregisterExporter(registrationID: registration)
        await dispatcher.record(try eventInput("after.removal"), source: recordingSource)
        #expect(receiver.events.map(\.input.eventName) == ["after.registration"])
    }

    @Test("excluding and including a plugin affects later events without replay")
    func exclusionDoesNotRevokeAcceptedEvents() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "test-installation", nectoVersion: "1.0.0")
        let receiver = EventReceiver()
        try await dispatcher.registerExporter(receive: receiver.accept)
        await dispatcher.record(try eventInput("accepted"), source: recordingSource)
        await dispatcher.updatePolicy(.init(excludedPluginIDs: ["tools"]))
        await dispatcher.record(try eventInput("while.excluded"), source: recordingSource)
        #expect(receiver.events.map(\.input.eventName) == ["accepted"])
        await dispatcher.updatePolicy(.init())
        #expect(receiver.events.map(\.input.eventName) == ["accepted"])
        await dispatcher.record(try eventInput("after.inclusion"), source: recordingSource)
        #expect(receiver.events.map(\.input.eventName) == ["accepted", "after.inclusion"])
    }

    @Test("records without a receiver are not buffered for a later registration")
    func unregisteredConcurrentRecordsAreNotBuffered() async throws {
        let dispatcher = NectoEventDispatcher(installationID: "test-installation", nectoVersion: "1.0.0")
        let receiver = EventReceiver()
        let input = try eventInput()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { await dispatcher.record(input, source: recordingSource) }
            }
        }
        try await dispatcher.registerExporter(receive: receiver.accept)
        #expect(receiver.events.isEmpty)
        await dispatcher.record(input, source: recordingSource)
        #expect(receiver.events.count == 1)
    }

    @Test("plugin exclusions also cover related host events but not unrelated host activity")
    func excludesByPluginID() async throws {
        let dispatcher = NectoEventDispatcher(
            installationID: "test-installation", nectoVersion: "1.0.0"
        )
        let receiver = EventReceiver()
        try await dispatcher.registerExporter(receive: receiver.accept)
        await dispatcher.record(try eventInput("already.accepted"), source: recordingSource)
        await dispatcher.updatePolicy(.init(excludedPluginIDs: ["tools"]))
        await dispatcher.record(try eventInput("excluded"), source: .device(id: "tools", version: "2.0.0"))
        await dispatcher.record(try eventInput("excluded.desktop"), source: .desktop(id: "tools", version: "3.0.0"))
        await dispatcher.record(try eventInput("panel.opened"), source: .necto(relatedPluginID: "tools"), channel: .ui)
        await dispatcher.record(try eventInput("new.plugin"), source: .device(id: "new-tools", version: "1.0.0"))
        await dispatcher.record(try eventInput("necto.launched"), source: .necto())
        #expect(receiver.events.map(\.input.eventName) == ["already.accepted", "new.plugin", "necto.launched"])
        let hostEvent = try #require(receiver.events.last)
        #expect(hostEvent.jsonValue["origin"] == "necto")
        #expect(hostEvent.jsonValue["pluginId"] == nil)
        #expect(hostEvent.jsonValue["channel"] == nil)
    }

    @Test("unregistering disconnects the receiver; stale cleanup cannot remove a new one")
    func replacementRegistrationIsIsolated() async throws {
        let dispatcher = NectoEventDispatcher(
            installationID: "test-installation", nectoVersion: "1.0.0"
        )
        let old = EventReceiver()
        let new = EventReceiver()
        let oldID = try await dispatcher.registerExporter(receive: old.accept)
        await dispatcher.unregisterExporter(registrationID: oldID)
        await dispatcher.record(try eventInput("between.registrations"), source: recordingSource)
        let newID = try await dispatcher.registerExporter(receive: new.accept)
        await dispatcher.unregisterExporter(registrationID: oldID)
        await dispatcher.record(try eventInput("new.receiver"), source: recordingSource)
        #expect(old.events.isEmpty)
        #expect(new.events.map(\.input.eventName) == ["new.receiver"])
        await dispatcher.unregisterExporter(registrationID: newID)
        await dispatcher.record(try eventInput("disconnected"), source: recordingSource)
        try await dispatcher.registerExporter(receive: new.accept)
        #expect(new.events.map(\.input.eventName) == ["new.receiver"])
    }

    @Test("invalid common envelopes and non-JSON numbers are rejected")
    func rejectsInvalidInput() throws {
        let invalid: [NectoJSONValue] = [
            .null,
            ["eventName": ""],
            ["eventName": "   "],
            ["eventName": "test", "kind": "action"],
            ["eventName": "test", "params": [1, 2]],
            ["eventName": "test", "pluginId": "another-plugin"],
            ["eventName": "test", "params": ["nested": [.number(.infinity)]]],
        ]
        for value in invalid {
            do {
                _ = try NectoEvent.Input(jsonValue: value)
                Issue.record("Invalid common input was accepted")
            } catch let error as NectoBridgeError {
                #expect(error.code == .invalidInput)
            }
        }
        let input = try NectoEvent.Input(jsonValue: ["eventName": "new.name"])
        #expect(input.params.isEmpty)
        #expect(input.eventName == "new.name")
    }
}
