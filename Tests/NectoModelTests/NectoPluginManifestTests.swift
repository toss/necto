//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoModel

private func makeBinding(
    name: String = "necto.desktop.network-records.list",
    version: Int = 1
) -> NectoBridgeBinding {
    NectoBridgeBinding(name: name, version: version)
}

private func makeOperation(
    id: String = "records.list",
    kind: NectoOperationKind = .once,
    binding: NectoBridgeBinding = makeBinding(),
    timeoutMs: Int = 5000
) -> NectoOperation {
    NectoOperation(
        id: id,
        title: "List network records",
        description: "Returns recorded requests",
        kind: kind,
        binding: binding,
        inputSchema: ["type": "object"],
        outputSchema: ["type": "object"],
        timeoutMs: timeoutMs
    )
}

private func makeManifest(
    operations: [NectoOperation] = [makeOperation()],
    version: String = "1.0.0"
) -> NectoPluginManifest {
    NectoPluginManifest(
        id: "network-logger",
        name: "Network Logger",
        description: "Inspect network requests",
        version: version,
        author: "Necto",
        icon: .init(systemName: "network"),
        assets: ["index.html"],
        allowedOrigins: ["self"],
        operations: operations
    )
}

@Test func acceptsValidManifest() throws {
    try makeManifest().validate()
}

@Test func acceptsAPureWebPluginWithoutHostOperations() throws {
    try makeManifest(operations: []).validate()
}

/// The name is the whole declaration, so one that says who answers it is the only
/// kind there is. A plugin contract will be addressed by plugin id instead, and will
/// not start with `necto.` at all.
@Test func rejectsABridgeThatNamesNoOwner() {
    let manifest = makeManifest(operations: [makeOperation(binding: makeBinding(name: "records.list"))])
    #expect(throws: NectoManifestValidationError.unknownBridgeOwner(
        operationID: "records.list",
        name: "records.list"
    )) {
        try manifest.validate()
    }
}

/// One power asked for twice would be shown twice and agreed to twice.
@Test func rejectsTwoOperationsBoundToOneBridge() {
    let manifest = makeManifest(operations: [makeOperation(), makeOperation(id: "records.all")])
    #expect(throws: NectoManifestValidationError.duplicateBinding(
        operationID: "records.all",
        name: "necto.desktop.network-records.list"
    )) {
        try manifest.validate()
    }
}

@Test func rejectsDuplicateOperationIDs() {
    let manifest = makeManifest(operations: [makeOperation(), makeOperation()])
    #expect(throws: NectoManifestValidationError.duplicateOperationID("records.list")) {
        try manifest.validate()
    }
}


@Test func rejectsNonSemanticVersion() {
    let manifest = makeManifest(version: "1.0")
    #expect(throws: NectoManifestValidationError.invalidVersion(field: "version", value: "1.0")) {
        try manifest.validate()
    }
}

@Test func requiresTargetOnlyWhenAppContractExists() {
    #expect(!makeManifest().requiresTarget)

    let appBound = makeManifest(
        operations: [makeOperation(binding: makeBinding(name: "necto.device.variables.list"))]
    )
    #expect(appBound.requiresTarget)
}

@Test func decodesManifestFromJSON() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "network-logger",
      "name": "Network Logger",
      "description": "Inspect network requests",
      "version": "1.0.0",
      "author": "Necto",
      "authorUrl": "https://example.com",
      "icon": { "systemName": "network" },
      "assets": ["index.html"],
      "allowedOrigins": ["self"],
      "operations": [
        {
          "id": "records.observe",
          "title": "Observe",
          "description": "Receives changes as they happen",
          "kind": "stream",
          "binding": {
            "name": "necto.desktop.network-records.observe",
            "version": 1
          },
          "inputSchema": { "type": "object" },
          "outputSchema": { "type": "object" },
          "timeoutMs": 0,
        }
      ]
    }
    """

    let manifest = try JSONDecoder().decode(NectoPluginManifest.self, from: Data(json.utf8))
    try manifest.validate()

    #expect(manifest.authorURL == "https://example.com")
    #expect(manifest.operations.first?.kind == .stream)
    #expect(manifest.operations.first?.binding == makeBinding(name: "necto.desktop.network-records.observe"))
    #expect(!manifest.requiresTarget)
}

/// A binding is a name and a number, and a name says who answers it.
@Test func readsTheOwnerOffTheName() {
    #expect(makeBinding(name: "necto.desktop.storage.set").type == .desktop)
    #expect(makeBinding(name: "necto.device.events.list").type == .device)
    #expect(makeBinding(name: "necto.storage.set").type == nil)
    #expect(makeBinding(name: "necto.desktop.storage.set").identity == "necto.desktop.storage.set@1")
}

/// Only a device bridge needs a connected app, and that is read off the name too.
@Test func onlyDeviceBridgesNeedATarget() {
    #expect(makeBinding(name: "necto.device.events.list").requiresTarget)
    #expect(!makeBinding(name: "necto.desktop.storage.set").requiresTarget)
}
