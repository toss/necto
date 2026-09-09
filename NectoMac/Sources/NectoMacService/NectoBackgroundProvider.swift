//
// Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel

/// Declaring this desktop bridge opts a panel into the app-owned background lifetime.
public struct NectoBackgroundProvider: NectoOperationProvider {
    public static let key = "necto.desktop.background.keepAlive"
    public let descriptor = NectoBridgeDescriptor(binding: NectoBridgeBinding(name: key, version: 1), kind: .once)
    public init() {}
    public func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        guard !context.principal.sourceIdentity.hasPrefix("device:") else {
            throw NectoBridgeError(code: .operationUnavailable, message: "Background lifetime is available to desktop plugins only.")
        }
        return ["active": true]
    }
}
