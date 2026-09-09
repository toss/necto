//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

private func requiredKey(_ input: NectoJSONValue) throws -> String {
    guard let key = input["key"]?.stringValue, !key.isEmpty else {
        throw NectoBridgeError(code: .invalidInput, message: "key must be a non-empty string")
    }
    return key
}

private func scope(for context: NectoInvocationContext, input: NectoJSONValue) throws -> NectoPluginStorage.Scope {
    let scope = input["scope"]?.stringValue ?? "target"
    guard scope == "target" || scope == "plugin" else {
        throw NectoBridgeError(code: .invalidInput, message: "Storage scope must be target or plugin.")
    }
    return NectoPluginStorage.Scope(principal: context.principal, target: context.target, isPluginWide: scope == "plugin")
}

private func binding(_ name: String) -> NectoBridgeBinding {
    NectoBridgeBinding(name: name, version: 1)
}

public struct NectoStorageGetProvider: NectoOperationProvider {
    public static let key = "necto.desktop.storage.get"

    public let descriptor = NectoBridgeDescriptor(
        binding: binding(key),
        kind: .once
    )

    private let storage: NectoPluginStorage

    public init(storage: NectoPluginStorage) {
        self.storage = storage
    }

    public func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        let value = await storage.value(forKey: try requiredKey(input), scope: try scope(for: context, input: input))

        // `found` is separate from `value` because a stored null and a missing key are
        // different answers, and a plugin has to be able to tell them apart.
        guard let value else { return ["found": false] }
        return ["found": true, "value": value]
    }
}

public struct NectoStorageSetProvider: NectoOperationProvider {
    public static let key = "necto.desktop.storage.set"

    public let descriptor = NectoBridgeDescriptor(
        binding: binding(key),
        kind: .once
    )

    private let storage: NectoPluginStorage

    public init(storage: NectoPluginStorage) {
        self.storage = storage
    }

    public func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        guard let value = input["value"] else {
            throw NectoBridgeError(code: .invalidInput, message: "value is required")
        }
        try await storage.setValue(value, forKey: try requiredKey(input), scope: try scope(for: context, input: input))
        return ["success": true]
    }
}

public struct NectoStorageRemoveProvider: NectoOperationProvider {
    public static let key = "necto.desktop.storage.remove"

    public let descriptor = NectoBridgeDescriptor(
        binding: binding(key),
        kind: .once
    )

    private let storage: NectoPluginStorage

    public init(storage: NectoPluginStorage) {
        self.storage = storage
    }

    public func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        try await storage.removeValue(forKey: try requiredKey(input), scope: try scope(for: context, input: input))
        return ["success": true]
    }
}

public struct NectoStorageKeysProvider: NectoOperationProvider {
    public static let key = "necto.desktop.storage.keys"

    public let descriptor = NectoBridgeDescriptor(
        binding: binding(key),
        kind: .once
    )

    private let storage: NectoPluginStorage

    public init(storage: NectoPluginStorage) {
        self.storage = storage
    }

    public func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        let keys = await storage.keys(matching: input["prefix"]?.stringValue, scope: try scope(for: context, input: input))
        return ["keys": .array(keys.map(NectoJSONValue.string))]
    }
}
