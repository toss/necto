//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoModel

private func makeHello(
    protocolVersion: Int = NectoProtocol.currentVersion,
    appBundleID: String = "com.example.app"
) -> NectoHandshakeHello {
    NectoHandshakeHello(
        protocolVersion: protocolVersion,
        appBundleID: appBundleID,
        appName: "Example",
        deviceName: "iPhone",
        sdkVersion: "0.1.0"
    )
}

@Test func acceptsAHelloOnTheCurrentProtocol() {
    let ack = NectoHandshakeAck.evaluate(makeHello())

    #expect(ack.accepted)
    #expect(ack.rejection == nil)
    #expect(ack.hostProtocolVersion == NectoProtocol.currentVersion)
}

@Test func failsTheConnectionOnAProtocolMismatch() {
    // Necto speaks one version. A newer or older peer is refused rather than negotiated.
    let older = NectoHandshakeAck.evaluate(makeHello(protocolVersion: 0))
    let newer = NectoHandshakeAck.evaluate(makeHello(protocolVersion: 2))

    #expect(!older.accepted)
    #expect(older.rejection == .unsupportedProtocolVersion)
    #expect(!newer.accepted)
    #expect(newer.rejection == .unsupportedProtocolVersion)
}

@Test func refusesAHelloWithoutAnAppIdentity() {
    let ack = NectoHandshakeAck.evaluate(makeHello(appBundleID: ""))

    #expect(!ack.accepted)
    #expect(ack.rejection == .missingAppIdentity)
}

@Test func roundTripsThroughJSON() throws {
    let hello = makeHello()
    let decoded = try JSONDecoder().decode(
        NectoHandshakeHello.self,
        from: JSONEncoder().encode(hello)
    )

    #expect(decoded == hello)
}
