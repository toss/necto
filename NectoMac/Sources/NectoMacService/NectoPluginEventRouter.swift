//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// Delivers `plugin.event` messages to whichever host adapter owns the channel.
///
/// The transport does not know what any channel means, and neither does this: it
/// matches a channel name to a handler and passes the payload through. A new SDK
/// plugin therefore needs a handler registered here and nothing else, and no new
/// message type on the wire.
public actor NectoPluginEventRouter {
    public typealias Handler = @Sendable (NectoJSONValue, NectoTarget) async -> Void

    private var handlers: [String: Handler] = [:]

    public init() {}

    public func on(channel: String, handler: @escaping Handler) {
        handlers[channel] = handler
    }

    public func route(_ event: NectoPluginEvent, from target: NectoTarget) async {
        await handlers[event.channel]?(event.payload, target)
    }
}
