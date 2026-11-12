//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel

/// Sends app events on behalf of the plugin that received this handle.
///
/// Keep this beyond `register(_:)` to log from the plugin's own callbacks. Calls
/// return immediately, never throw, and are dropped without a connected host.
/// Unregistering the plugin permanently retires its logger, even if the same ID
/// is registered again. Events are never retained for a later connection.
/// Delivery is best effort; events sent before the host receives the plugin's
/// registration may also be dropped.
public struct NectoPluginLogger: Sendable {
    private let send: @Sendable (String, [String: NectoJSONValue]) -> Void

    init(send: @escaping @Sendable (String, [String: NectoJSONValue]) -> Void = { _, _ in }) {
        self.send = send
    }

    public func log(_ eventName: String, params: [String: NectoJSONValue] = [:]) {
        send(eventName, params)
    }
}
