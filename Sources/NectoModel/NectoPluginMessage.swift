//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// App to host. Sent once the handshake is accepted.
///
/// The host will not call a contract that was not registered, and will not call one
/// whose declared shape disagrees with the manifest the plugin was installed with.
public struct NectoPluginRegistration: Sendable, Hashable, Codable {
    public let pluginID: String
    public let catalog: NectoBridgeCatalog
    /// Present when the plugin carries its own panel. Old registrations without the
    /// key still decode — a plugin without a panel is simply one the host has to be
    /// given a panel for.
    public let panel: NectoPanelStamp?

    public init(pluginID: String, catalog: NectoBridgeCatalog, panel: NectoPanelStamp? = nil) {
        self.pluginID = pluginID
        self.catalog = catalog
        self.panel = panel
    }
}

/// App to host. An SDK plugin pushing data that a host adapter accumulates.
///
/// `channel` is what a host adapter subscribes to. The transport never looks inside
/// `payload`; only the adapter that owns the channel knows its shape.
public struct NectoPluginEvent: Sendable, Hashable, Codable {
    public let pluginID: String
    public let channel: String
    public let payload: NectoJSONValue

    public init(pluginID: String, channel: String, payload: NectoJSONValue) {
        self.pluginID = pluginID
        self.channel = channel
        self.payload = payload
    }
}

/// Host to app. One call against a registered app contract.
public struct NectoPluginInvocation: Sendable, Hashable, Codable {
    public let requestID: String
    public let name: String
    public let version: Int
    public let kind: NectoOperationKind
    public let input: NectoJSONValue

    public init(
        requestID: String,
        name: String,
        version: Int,
        kind: NectoOperationKind,
        input: NectoJSONValue
    ) {
        self.requestID = requestID
        self.name = name
        self.version = version
        self.kind = kind
        self.input = input
    }
}

/// App to host. The reply to an invocation.
///
/// A `query` or `command` produces exactly one of these. A `stream` produces many,
/// each with `isFinal` false, and then one final message that carries either an error
/// or nothing at all.
public struct NectoPluginResult: Sendable, Hashable, Codable {
    public let requestID: String
    public let output: NectoJSONValue?
    public let error: NectoBridgeError?
    public let isFinal: Bool

    public init(
        requestID: String,
        output: NectoJSONValue? = nil,
        error: NectoBridgeError? = nil,
        isFinal: Bool = true
    ) {
        self.requestID = requestID
        self.output = output
        self.error = error
        self.isFinal = isFinal
    }
}

/// Host to app. Ends a stream the host no longer reads.
public struct NectoPluginCancel: Sendable, Hashable, Codable {
    public let requestID: String

    public init(requestID: String) {
        self.requestID = requestID
    }
}
