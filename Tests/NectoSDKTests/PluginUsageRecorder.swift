//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
@testable import NectoSDK

struct RecordedPluginUsage: Sendable, Equatable {
    let name: String
    let params: [String: NectoJSONValue]
}

final class PluginUsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedPluginUsage] = []

    var events: [RecordedPluginUsage] { lock.withLock { recorded } }

    func register(_ plugin: any NectoPlugin) -> NectoRegistrar {
        let logger = NectoPluginLogger { [self] name, params in
            lock.withLock { recorded.append(.init(name: name, params: params)) }
        }
        let registrar = NectoRegistrar(logger: logger)
        plugin.register(registrar)
        return registrar
    }

    func call(
        _ registrar: NectoRegistrar,
        _ operation: String,
        input: NectoJSONValue = [:]
    ) async throws -> NectoJSONValue {
        guard case let .once(body)? = registrar.registrations["necto.device.\(operation)@1"]?.body else {
            throw NectoBridgeError(code: .operationUnavailable, message: operation)
        }
        return try await body(input)
    }
}
