//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// The identity of an installed plugin. Storage and files are isolated by it.
public struct NectoPluginPrincipal: Sendable, Hashable, Codable {
    public let pluginID: String
    /// Where the plugin was installed from. The same id from a different source is a different principal.
    public let sourceIdentity: String

    public init(pluginID: String, sourceIdentity: String) {
        self.pluginID = pluginID
        self.sourceIdentity = sourceIdentity
    }
}

public struct NectoInvocationContext: Sendable {
    public let principal: NectoPluginPrincipal
    public let target: NectoTarget?
    public let requestID: String

    public init(
        principal: NectoPluginPrincipal,
        target: NectoTarget?,
        requestID: String = UUID().uuidString
    ) {
        self.principal = principal
        self.target = target
        self.requestID = requestID
    }
}

/// Host providers come from the Mac app, app providers from the connected app.
///
/// Both answer through the same protocol, so a surface never learns where a bridge
/// physically lives.
public protocol NectoOperationProvider: Sendable {
    var descriptor: NectoBridgeDescriptor { get }

    func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue

    func subscribe(
        input: NectoJSONValue,
        context: NectoInvocationContext
    ) async throws -> AsyncThrowingStream<NectoJSONValue, any Error>
}

public extension NectoOperationProvider {
    func invoke(input _: NectoJSONValue, context _: NectoInvocationContext) async throws -> NectoJSONValue {
        throw NectoBridgeError(
            code: .operationUnavailable,
            message: "This provider does not support invoke"
        )
    }

    func subscribe(
        input _: NectoJSONValue,
        context _: NectoInvocationContext
    ) async throws -> AsyncThrowingStream<NectoJSONValue, any Error> {
        throw NectoBridgeError(
            code: .operationUnavailable,
            message: "This provider does not support subscribe"
        )
    }
}
