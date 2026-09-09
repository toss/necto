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
