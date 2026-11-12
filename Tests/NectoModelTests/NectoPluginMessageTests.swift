//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoModel

@Test func wireCarriesOnlyGenericPluginKinds() {
    // The harness rule in code form: a feature never gets its own message kind, so a
    // new permission cannot quietly become part of the protocol.
    let kinds = Set(
        [
            NectoEnvelope.Kind.pluginRegister,
            .pluginEvent,
            .pluginInvoke,
            .pluginResult,
            .pluginCancel,
        ].map(\.rawValue)
    )

    #expect(kinds == ["plugin.register", "plugin.event", "plugin.invoke", "plugin.result", "plugin.cancel"])
    #expect(!kinds.contains { $0.hasPrefix("network.") })
}

@Test func routesAnEventWithoutUnderstandingIt() throws {
    // The transport moves a payload it has no schema for. That is what lets a plugin
    // ship without the SDK changing.
    let payload: NectoJSONValue = ["anything": ["nested": true]]
    let event = NectoPluginEvent(pluginID: "necto.network", channel: "necto.network-records", payload: payload)

    let envelope = try NectoEnvelope(type: .pluginEvent, encoding: event)
    let decoded = try envelope.decode(NectoPluginEvent.self)

    #expect(decoded.channel == "necto.network-records")
    #expect(decoded.payload == payload)
}

@Test func invocationChannelRoundTripsOnInvocationsAndEvents() throws {
    for (channel, wireValue) in [(NectoInvocationChannel.web, "web"), (.cli, "cli")] {
        let invocation = NectoPluginInvocation(
            requestID: "r1",
            name: "necto.device.example",
            version: 1,
            kind: .once,
            input: [:],
            invocationChannel: channel
        )
        let event = NectoPluginEvent(
            pluginID: "com.example.logger",
            channel: "necto.usage",
            payload: ["eventName": "example.called", "params": [:]],
            invocationChannel: channel
        )
        let invokeEnvelope = try NectoEnvelope(type: .pluginInvoke, encoding: invocation)
        let eventEnvelope = try NectoEnvelope(type: .pluginEvent, encoding: event)

        #expect(invokeEnvelope.payload["invocationChannel"] == .string(wireValue))
        #expect(eventEnvelope.payload["invocationChannel"] == .string(wireValue))
        #expect(eventEnvelope.payload["channel"] == "necto.usage")
        #expect(try invokeEnvelope.decode(NectoPluginInvocation.self) == invocation)
        #expect(try eventEnvelope.decode(NectoPluginEvent.self) == event)
    }
}

@Test func legacyInvocationsAndEventsOmitInvocationChannel() throws {
    let invokeEnvelope = NectoEnvelope(type: .pluginInvoke, payload: [
        "requestID": "r1",
        "name": "necto.device.example",
        "version": 1,
        "kind": "once",
        "input": [:],
    ])
    let eventEnvelope = NectoEnvelope(type: .pluginEvent, payload: [
        "pluginID": "com.example.logger",
        "channel": "necto.usage",
        "payload": ["eventName": "example.called", "params": [:]],
    ])
    let invocation = try invokeEnvelope.decode(NectoPluginInvocation.self)
    let event = try eventEnvelope.decode(NectoPluginEvent.self)

    #expect(invocation.invocationChannel == nil)
    #expect(event.invocationChannel == nil)
    #expect(try NectoEnvelope(type: .pluginInvoke, encoding: invocation) == invokeEnvelope)
    #expect(try NectoEnvelope(type: .pluginEvent, encoding: event) == eventEnvelope)
}

@Test func streamResultsAreNotFinalUntilTheLastOne() throws {
    let event = NectoPluginResult(requestID: "r1", output: ["n": 1], isFinal: false)
    let end = NectoPluginResult(requestID: "r1")

    #expect(!event.isFinal)
    #expect(end.isFinal)
    #expect(end.output == nil)
    #expect(end.error == nil)

    let roundTripped = try NectoEnvelope(type: .pluginResult, encoding: event).decode(NectoPluginResult.self)
    #expect(roundTripped == event)
}

@Test func failedResultCarriesTheBridgeErrorCode() throws {
    let result = NectoPluginResult(
        requestID: "r1",
        error: NectoBridgeError(code: .timeout, message: "took too long")
    )

    let decoded = try NectoEnvelope(type: .pluginResult, encoding: result).decode(NectoPluginResult.self)
    #expect(decoded.error?.code == .timeout)
}

@Test func catalogIsVersionedSeparatelyFromTheProtocol() throws {
    // Catalog, manifest and wire protocol all start at 1 but evolve independently, so
    // they must not be read from one number.
    let catalog = NectoBridgeCatalog(bridges: [
        NectoBridgeDescriptor(
            binding: NectoBridgeBinding(name: "necto.device.com.example.variables", version: 2),
            kind: .once
        ),
    ])

    let registration = NectoPluginRegistration(pluginID: "example", catalog: catalog)
    let decoded = try NectoEnvelope(type: .pluginRegister, encoding: registration)
        .decode(NectoPluginRegistration.self)

    #expect(decoded.catalog.catalogVersion == 1)
    #expect(decoded.catalog.bridges.first?.version == 2)
    #expect(decoded.catalog.bridges.first?.identity == "necto.device.com.example.variables@2")
}

@Test func registrationPresenceDistinguishesLoggerOnlyPluginsFromRemoval() throws {
    let catalog = NectoBridgeCatalog(bridges: [])
    for isRegistered in [true, false] {
        let registration = NectoPluginRegistration(
            pluginID: "com.example.logger", catalog: catalog, isRegistered: isRegistered
        )
        let decoded = try NectoEnvelope(type: .pluginRegister, encoding: registration)
            .decode(NectoPluginRegistration.self)
        #expect(decoded.isRegistered == isRegistered)
        #expect(decoded.isActive == isRegistered)
    }
    let removed = NectoPluginRegistration(
        pluginID: "com.example.logger", catalog: catalog,
        panel: NectoPanelStamp(hash: "previous-panel"), isRegistered: false
    )
    #expect(!removed.isActive)
}

@Test func legacyRegistrationsStillUseTheirCatalogForPresence() throws {
    let catalog = NectoBridgeCatalog(bridges: [
        NectoBridgeDescriptor(binding: NectoBridgeBinding(name: "necto.device.example", version: 1), kind: .once),
    ])
    for (catalog, active) in [(catalog, true), (NectoBridgeCatalog(bridges: []), false)] {
        let old = NectoPluginRegistration(pluginID: "com.example.legacy", catalog: catalog)
        let data = try JSONEncoder().encode(old)
        #expect(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])["isRegistered"] == nil)
        let decoded = try JSONDecoder().decode(NectoPluginRegistration.self, from: data)
        #expect(decoded.isRegistered == nil)
        #expect(decoded.isActive == active)
    }
    let panelOnly = NectoPluginRegistration(
        pluginID: "com.example.legacy", catalog: NectoBridgeCatalog(bridges: []),
        panel: NectoPanelStamp(hash: "legacy-panel")
    )
    let decodedPanel = try NectoEnvelope(type: .pluginRegister, encoding: panelOnly)
        .decode(NectoPluginRegistration.self)
    #expect(decodedPanel.isRegistered == nil)
    #expect(decodedPanel.isActive)
}
