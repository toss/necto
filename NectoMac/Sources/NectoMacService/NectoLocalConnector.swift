//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoTransport

/// Reaches an app running in a simulator.
///
/// A simulator shares the Mac's network stack, so an app listening inside it is
/// listening on the Mac's loopback. No usbmuxd tunnel is involved, which makes this
/// the quickest way to exercise a session while developing.
///
/// Only one simulator can hold a given port, because they all bind the same loopback.
/// Devices do not have that limit: each one has its own port namespace behind usbmuxd.
public enum NectoLocalConnector {
    public enum Failure: Error, CustomStringConvertible {
        case cannotConnect(port: UInt16, reason: String)

        public var description: String {
            switch self {
            case let .cannotConnect(port, reason):
                "Nothing is listening on 127.0.0.1:\(port) (\(reason)). Is the app running in a simulator?"
            }
        }
    }

    public static func connect(
        port: UInt16 = NectoTransportDefaults.devicePort
    ) async throws -> NectoMessageSession {
        do {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            let stream = try await NectoSocketStream.connect(to: address)
            return NectoMessageSession(stream: stream)
        } catch {
            throw Failure.cannotConnect(port: port, reason: String(describing: error))
        }
    }
}
