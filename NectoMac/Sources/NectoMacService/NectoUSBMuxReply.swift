//
//  Copyright (c) 2026 Viva Republica, Inc.
//

/// Result codes usbmuxd returns in the `Number` field of a reply.
public enum NectoUSBMuxReply: Sendable, Equatable, CustomStringConvertible {
    case ok
    case badCommand
    case badDevice
    case connectionRefused
    case badVersion
    case unknown(Int)

    init(number: Int?) {
        switch number {
        case 0: self = .ok
        case 1: self = .badCommand
        case 2: self = .badDevice
        case 3: self = .connectionRefused
        case 6: self = .badVersion
        case let other: self = .unknown(other ?? -1)
        }
    }

    public var description: String {
        switch self {
        case .ok: "OK"
        case .badCommand: "usbmuxd rejected the command"
        case .badDevice: "usbmuxd does not know that device. It may have been unplugged."
        case .connectionRefused:
            "The device refused the connection. The app is probably not running or not listening."
        case .badVersion: "usbmuxd rejected the protocol version"
        case let .unknown(code): "usbmuxd returned an unexpected result (\(code))"
        }
    }
}
