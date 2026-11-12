//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoModel

private let binding = NectoBridgeBinding(name: "necto.desktop.network-records.list", version: 1)

private func makeDescriptor(
    binding: NectoBridgeBinding = binding,
    kind: NectoOperationKind = .once,
) -> NectoBridgeDescriptor {
    NectoBridgeDescriptor(
        binding: binding,
        kind: kind,
    )
}

private func makeOperation(
    binding: NectoBridgeBinding = binding,
    kind: NectoOperationKind = .once,
) -> NectoOperation {
    NectoOperation(
        id: "records.list",
        title: "List",
        description: "Recorded requests",
        kind: kind,
        binding: binding,
        inputSchema: ["type": "object"],
        outputSchema: ["type": "object"],
        timeoutMs: 1000
    )
}

@Test func acceptsAProviderThatAgreesOnEveryRoutingField() {
    #expect(makeDescriptor().mismatch(with: makeOperation()) == nil)
}

/// Matching on the name alone would accept an incompatible version or operation kind.
/// Each routing field is checked separately so a regression names what it broke.
@Test func rejectsAProviderThatDisagreesOnName() {
    let elsewhere = NectoBridgeBinding(name: "necto.device.variables.list", version: binding.version)
    #expect(makeDescriptor().mismatch(with: makeOperation(binding: elsewhere))?.contains("is named") == true)
}

/// The version only moves when a bridge changed so much it cannot be read, so a plugin
/// that asked for the old one is refused rather than handed the new one.
@Test func rejectsAProviderThatDisagreesOnVersion() {
    let v2 = NectoBridgeBinding(name: binding.name, version: 2)
    #expect(makeDescriptor().mismatch(with: makeOperation(binding: v2))?.contains("version") == true)
}

@Test func rejectsAProviderThatDisagreesOnKind() {
    #expect(makeDescriptor(kind: .stream).mismatch(with: makeOperation())?.contains("stream") == true)
}



@Test func destructiveBridgesAreDistinguishableFromReads() {
    let clear = makeDescriptor()
    #expect(clear.kind == .once)

    let data = try! JSONEncoder().encode(clear)
    let decoded = try! JSONDecoder().decode(NectoBridgeDescriptor.self, from: data)
    #expect(decoded.kind == .once)
}
