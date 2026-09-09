//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// The wrapper every message after the handshake travels in.
///
/// A session carries several kinds of traffic, and the reader has to know what it is
/// holding before decoding it. `type` is that discriminator; `payload` stays opaque
/// until the reader picks a concrete type for it.
///
/// Every kind here is about *plugins in general*. No feature ever gets its own kind:
/// a feature is a plugin on one side and an adapter on the other, and what it sends
/// travels inside `plugin.event` or `plugin.invoke`. That is what keeps the SDK a
/// bridge rather than a bag of features.
public struct NectoEnvelope: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// App to host, once per connection: the app contracts this app answers.
        case pluginRegister = "plugin.register"
        /// App to host: an event on a plugin's channel.
        case pluginEvent = "plugin.event"
        /// Host to app: run one app contract.
        case pluginInvoke = "plugin.invoke"
        /// App to host: the answer to an invoke, or one event of a subscribed stream.
        case pluginResult = "plugin.result"
        /// Host to app: stop a stream that is still running.
        case pluginCancel = "plugin.cancel"
    }

    public let type: Kind
    public let payload: NectoJSONValue

    public init(type: Kind, payload: NectoJSONValue) {
        self.type = type
        self.payload = payload
    }

    public init(type: Kind, encoding value: some Encodable) throws {
        self.init(type: type, payload: try NectoJSONValue(encoding: value))
    }

    public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try payload.decode(type)
    }
}
