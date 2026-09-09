//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoTransport

/// An iOS device attached over USB, as reported by usbmuxd.
public struct NectoUSBDevice: Sendable, Hashable, Identifiable {
    /// usbmuxd's own handle for the device. Only valid while the device stays attached.
    public let deviceID: Int
    /// The device UDID.
    public let serialNumber: String
    public let connectionType: String

    public var id: Int { deviceID }
    public var isUSB: Bool { connectionType == "USB" }
}

public enum NectoUSBDeviceEvent: Sendable {
    case attached(NectoUSBDevice)
    case detached(deviceID: Int)
}

/// Talks to usbmuxd, the daemon macOS already uses to reach attached iOS devices.
///
/// Mirrors `PTUSBHub` in PeerTalk. Reimplemented in Swift rather than depending on
/// PeerTalk: the protocol is a plist exchange over a unix socket, and keeping it in
/// Swift avoids an Objective-C dependency in a Swift package.
///
/// USB discovery and tunneling use the local usbmuxd socket protocol.
public enum NectoUSBHub {
    enum Failure: Error {
        case connectFailed(NectoUSBMuxReply)
    }

    private static let clientName = "Necto"

    public static func listDevices() async throws -> [NectoUSBDevice] {
        let channel = try await NectoUSBChannel()
        defer { channel.close() }
        return try await NectoMessageSession(stream: channel).handshake {
            try await channel.send(request: request(messageType: "ListDevices"))
            let response = try await channel.receiveResponse()
            let entries = response["DeviceList"] as? [[String: Any]] ?? []
            return entries.compactMap(device(from:))
        }
    }

    /// Emits an event whenever a device attaches or detaches.
    ///
    /// usbmuxd replays the currently attached devices as `attached` right after the
    /// listen request, so a subscriber needs no separate initial listing.
    public static func deviceEvents() -> AsyncThrowingStream<NectoUSBDeviceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let channel = try await NectoUSBChannel()
                    defer { channel.close() }
                    try await channel.send(request: request(messageType: "Listen"))
                    while !Task.isCancelled {
                        let message = try await channel.receiveResponse()
                        if let event = event(from: message) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens a tunnel to a TCP port on the device.
    ///
    /// Mirrors `-connectToDevice:port:onStart:onEnd:`, including the byte swap the
    /// port needs.
    public static func connect(deviceID: Int, port: UInt16) async throws -> NectoMessageSession {
        let channel = try await NectoUSBChannel()
        let session = NectoMessageSession(stream: channel)
        do {
            try await session.handshake {
                // usbmuxd expects network byte order even inside the plist integer.
                try await channel.send(request: [
                    "MessageType": "Connect",
                    "ClientVersionString": clientName,
                    "ProgName": clientName,
                    "DeviceID": deviceID,
                    "PortNumber": Int(port.bigEndian),
                ])

                let response = try await channel.receiveResponse()
                let reply = NectoUSBMuxReply(number: response["Number"] as? Int)
                guard reply == .ok else { throw Failure.connectFailed(reply) }
            }
            return session
        } catch {
            session.close()
            throw error
        }
    }

    /// The port lockdownd listens on, on every iOS device.
    private static let lockdownPort: UInt16 = 62078

    /// Asks the device for the name its owner gave it.
    ///
    /// iOS stopped handing that name to apps without a special entitlement, so the
    /// SDK can only report "iPhone". lockdownd still answers the Mac, which is the
    /// side that already has the right to ask, so the nicer name is fetched here
    /// rather than requiring every app that embeds Necto to hold an entitlement.
    ///
    /// Returns nil when lockdownd declines, which costs nothing: the name the app
    /// reported is used instead.
    public static func deviceName(deviceID: Int) async -> String? {
        guard let session = try? await connect(deviceID: deviceID, port: lockdownPort) else {
            return nil
        }
        defer { session.close() }

        return try? await session.handshake { await query(session: session) }
    }

    private static func query(session: NectoMessageSession) async -> String? {
        let request: [String: Any] = [
            "Request": "GetValue",
            "Key": "DeviceName",
            "Label": clientName,
        ]

        do {
            let body = try PropertyListSerialization.data(
                fromPropertyList: request,
                format: .xml,
                options: 0
            )
            try await session.send(body)

            let response = try PropertyListSerialization.propertyList(
                from: try await session.receive(),
                options: [],
                format: nil
            ) as? [String: Any]

            guard let name = response?["Value"] as? String, !name.isEmpty else { return nil }
            return name
        } catch {
            return nil
        }
    }

    private static func request(messageType: String) -> [String: Any] {
        [
            "MessageType": messageType,
            "ClientVersionString": clientName,
            "ProgName": clientName,
            "kLibUSBMuxVersion": 3,
        ]
    }

    private static func device(from entry: [String: Any]) -> NectoUSBDevice? {
        guard let properties = entry["Properties"] as? [String: Any],
              let deviceID = properties["DeviceID"] as? Int,
              let serialNumber = properties["SerialNumber"] as? String
        else { return nil }

        return NectoUSBDevice(
            deviceID: deviceID,
            serialNumber: serialNumber,
            connectionType: properties["ConnectionType"] as? String ?? "Unknown"
        )
    }

    private static func event(from message: [String: Any]) -> NectoUSBDeviceEvent? {
        switch message["MessageType"] as? String {
        case "Attached":
            guard let device = device(from: message) else { return nil }
            return .attached(device)
        case "Detached":
            guard let deviceID = message["DeviceID"] as? Int else { return nil }
            return .detached(deviceID: deviceID)
        default:
            return nil
        }
    }
}
