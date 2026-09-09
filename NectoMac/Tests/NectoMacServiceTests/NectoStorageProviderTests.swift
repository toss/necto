//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoMacService

private let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
private let otherTarget = NectoTarget(deviceID: "device-2", appBundleID: "com.example.other")

private func makeStorage() -> NectoPluginStorage {
    // A temporary directory, never the real Application Support: a test must not read
    // or overwrite what a developer's own Necto has stored.
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "necto-storage-tests/\(UUID().uuidString)")
    return NectoPluginStorage(directory: directory)
}

private func makeContext(
    pluginID: String = "network-logger",
    sourceIdentity: String = "builtin",
    target: NectoTarget? = target
) -> NectoInvocationContext {
    NectoInvocationContext(
        principal: NectoPluginPrincipal(pluginID: pluginID, sourceIdentity: sourceIdentity),
        target: target
    )
}

@Test func storesAndReadsBackAValue() async throws {
    let storage = makeStorage()
    let context = makeContext()

    _ = try await NectoStorageSetProvider(storage: storage)
        .invoke(input: ["key": "lastAccount", "value": ["accountID": "demo"]], context: context)

    let result = try await NectoStorageGetProvider(storage: storage)
        .invoke(input: ["key": "lastAccount"], context: context)

    #expect(result["found"]?.boolValue == true)
    #expect(result["value"]?["accountID"]?.stringValue == "demo")
}

@Test func aMissingKeyIsNotFoundRatherThanNull() async throws {
    // A stored null and a missing key are different answers, and a plugin has to be
    // able to tell them apart.
    let storage = makeStorage()
    let context = makeContext()

    let missing = try await NectoStorageGetProvider(storage: storage)
        .invoke(input: ["key": "never-written"], context: context)
    #expect(missing["found"]?.boolValue == false)

    _ = try await NectoStorageSetProvider(storage: storage)
        .invoke(input: ["key": "explicit", "value": .null], context: context)

    let stored = try await NectoStorageGetProvider(storage: storage)
        .invoke(input: ["key": "explicit"], context: context)
    #expect(stored["found"]?.boolValue == true)
    #expect(stored["value"] == .null)
}

@Test func onePluginCannotReadAnother() async throws {
    let storage = makeStorage()

    _ = try await NectoStorageSetProvider(storage: storage)
        .invoke(input: ["key": "secret", "value": "mine"], context: makeContext(pluginID: "first"))

    let other = try await NectoStorageGetProvider(storage: storage)
        .invoke(input: ["key": "secret"], context: makeContext(pluginID: "second"))

    #expect(other["found"]?.boolValue == false)
}

@Test func theSameIDFromAnotherSourceIsAnotherPrincipal() async throws {
    // An id is not an identity. A plugin sideloaded under the name of a built-in one
    // must not inherit its storage.
    let storage = makeStorage()

    _ = try await NectoStorageSetProvider(storage: storage)
        .invoke(input: ["key": "secret", "value": "mine"], context: makeContext(sourceIdentity: "builtin"))

    let impostor = try await NectoStorageGetProvider(storage: storage)
        .invoke(input: ["key": "secret"], context: makeContext(sourceIdentity: "sideloaded"))

    #expect(impostor["found"]?.boolValue == false)
}

@Test func valuesAreKeptApartPerTarget() async throws {
    let storage = makeStorage()

    _ = try await NectoStorageSetProvider(storage: storage)
        .invoke(input: ["key": "filter", "value": "a"], context: makeContext(target: target))
    _ = try await NectoStorageSetProvider(storage: storage)
        .invoke(input: ["key": "filter", "value": "b"], context: makeContext(target: otherTarget))

    let first = try await NectoStorageGetProvider(storage: storage)
        .invoke(input: ["key": "filter"], context: makeContext(target: target))
    #expect(first["value"]?.stringValue == "a")

    let second = try await NectoStorageGetProvider(storage: storage)
        .invoke(input: ["key": "filter"], context: makeContext(target: otherTarget))
    #expect(second["value"]?.stringValue == "b")
}

@Test func listsAndFiltersKeys() async throws {
    let storage = makeStorage()
    let context = makeContext()
    let set = NectoStorageSetProvider(storage: storage)

    _ = try await set.invoke(input: ["key": "account.a", "value": 1], context: context)
    _ = try await set.invoke(input: ["key": "account.b", "value": 2], context: context)
    _ = try await set.invoke(input: ["key": "other", "value": 3], context: context)

    let all = try await NectoStorageKeysProvider(storage: storage).invoke(input: .object([:]), context: context)
    #expect(all["keys"] == ["account.a", "account.b", "other"])

    let filtered = try await NectoStorageKeysProvider(storage: storage)
        .invoke(input: ["prefix": "account."], context: context)
    #expect(filtered["keys"] == ["account.a", "account.b"])
}

@Test func removesAValue() async throws {
    let storage = makeStorage()
    let context = makeContext()

    _ = try await NectoStorageSetProvider(storage: storage)
        .invoke(input: ["key": "temporary", "value": 1], context: context)
    _ = try await NectoStorageRemoveProvider(storage: storage)
        .invoke(input: ["key": "temporary"], context: context)

    let result = try await NectoStorageGetProvider(storage: storage)
        .invoke(input: ["key": "temporary"], context: context)
    #expect(result["found"]?.boolValue == false)
}

@Test func rejectsAnEmptyKey() async {
    let storage = makeStorage()

    await #expect(throws: NectoBridgeError.self) {
        _ = try await NectoStorageGetProvider(storage: storage)
            .invoke(input: ["key": ""], context: makeContext())
    }
    await #expect(throws: NectoBridgeError.self) {
        _ = try await NectoStorageSetProvider(storage: storage)
            .invoke(input: ["value": 1], context: makeContext())
    }
}

@Test func survivesAReopen() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "necto-storage-tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = makeContext()

    _ = try await NectoStorageSetProvider(storage: NectoPluginStorage(directory: directory))
        .invoke(input: ["key": "kept", "value": "yes"], context: context)

    let reopened = try await NectoStorageGetProvider(storage: NectoPluginStorage(directory: directory))
        .invoke(input: ["key": "kept"], context: context)
    #expect(reopened["value"]?.stringValue == "yes")
}

@Test func storageScopeHasAStableDigest() {
    let scope = NectoPluginStorage.Scope(
        principal: .init(pluginID: "network-logger", sourceIdentity: "builtin"), target: target
    )
    // A fixed vector catches process-randomized hashing and accidental format changes.
    #expect(scope.identity == "2de52b8ad1ad103fe8c18eeccc6bf3ea3149ed2da7e38ff3d25b2f02803eb8a9")
}

@Test func storageScopePreservesFieldBoundariesAndMissingTarget() {
    let first = NectoPluginStorage.Scope(
        principal: .init(pluginID: "ab", sourceIdentity: "c"), target: nil
    )
    let second = NectoPluginStorage.Scope(
        principal: .init(pluginID: "a", sourceIdentity: "bc"), target: nil
    )
    let emptyTarget = NectoPluginStorage.Scope(
        principal: .init(pluginID: "ab", sourceIdentity: "c"),
        target: .init(deviceID: "", appBundleID: "")
    )
    #expect(Set([first.identity, second.identity, emptyTarget.identity]).count == 3)
}

@Test func failedStorageWriteDoesNotPublishAnUnsavedValue() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "necto-storage-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "storage")
    let storage = NectoPluginStorage(directory: directory)
    let scope = NectoPluginStorage.Scope(
        principal: .init(pluginID: "network-logger", sourceIdentity: "builtin"), target: target
    )
    try await storage.setValue("saved", forKey: "value", scope: scope)
    try FileManager.default.removeItem(at: directory)
    try Data().write(to: directory)

    await #expect(throws: (any Error).self) {
        try await storage.setValue("unsaved", forKey: "value", scope: scope)
    }
    #expect(await storage.value(forKey: "value", scope: scope) == "saved")
    await #expect(throws: (any Error).self) {
        try await storage.removeValue(forKey: "value", scope: scope)
    }
    #expect(await storage.value(forKey: "value", scope: scope) == "saved")
}

/// Four bridges, one place they live. The name says who answers them, so an install
/// dialog can group them without being told separately.
@Test func storageBridgesAreAllAnsweredByTheDesktop() {
    let storage = makeStorage()
    let names = [
        NectoStorageGetProvider(storage: storage).descriptor.binding,
        NectoStorageSetProvider(storage: storage).descriptor.binding,
        NectoStorageRemoveProvider(storage: storage).descriptor.binding,
        NectoStorageKeysProvider(storage: storage).descriptor.binding,
    ]

    #expect(names.allSatisfy { $0.type == .desktop })
    #expect(Set(names.map(\.name)) == [
        "necto.desktop.storage.get",
        "necto.desktop.storage.set",
        "necto.desktop.storage.remove",
        "necto.desktop.storage.keys",
    ])
}

/// Reading and writing a key are the same kind of call: both answer once. Which one it
/// is, is in the name.
@Test func everyStorageBridgeAnswersOnce() {
    let storage = makeStorage()
    #expect(NectoStorageGetProvider(storage: storage).descriptor.kind == .once)
    #expect(NectoStorageSetProvider(storage: storage).descriptor.kind == .once)
    #expect(NectoStorageRemoveProvider(storage: storage).descriptor.kind == .once)
}

// The plugin-wide namespace is stable across processes and independent of device selection.
@Test func pluginWideStorageNamespaceIsStableAcrossProcesses() {
    let principal = NectoPluginPrincipal(pluginID: "sample", sourceIdentity: "installation:first")
    let first = NectoPluginStorage.Scope(principal: principal, target: target, isPluginWide: true)
    let second = NectoPluginStorage.Scope(principal: principal, target: otherTarget, isPluginWide: true)
    #expect(first.identity == second.identity)
    #expect(first.identity == "plugin-7b18c052349e0b1ad37b86f23b1e145edc46de74c5d159b23b81845b99bd4ff6")
}
