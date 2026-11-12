//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// State of one operation declared in the plugin manifest.
public struct NectoAvailableOperation: Sendable, Hashable, Codable {
    public let id: String
    public let kind: NectoOperationKind
    public let available: Bool
    /// Why the operation cannot be used. Safe to show to the user as-is.
    public let unavailableReason: String?

    public init(
        id: String,
        kind: NectoOperationKind,
        available: Bool,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.available = available
        self.unavailableReason = unavailableReason
    }
}

/// The value returned by `NectoBridge.context()`.
///
/// This is the only way a plugin learns its identity, its available operations and
/// the selected target. It never carries an API base URL or an authentication token.
public struct NectoPluginContext: Sendable, Hashable, Codable {
    public let protocolVersion: Int
    public let pluginID: String
    public let pluginVersion: String
    public let sourceIdentity: String
    public let operations: [NectoAvailableOperation]
    public let target: NectoTargetInfo?

    public init(
        protocolVersion: Int = NectoProtocol.currentVersion,
        pluginID: String,
        pluginVersion: String,
        sourceIdentity: String,
        operations: [NectoAvailableOperation],
        target: NectoTargetInfo?
    ) {
        self.protocolVersion = protocolVersion
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.sourceIdentity = sourceIdentity
        self.operations = operations
        self.target = target
    }
}
