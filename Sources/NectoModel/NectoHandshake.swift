//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// The first message on a new connection, sent by the app.
///
/// The app speaks first because it is the side that knows its own identity. The Mac
/// only learns which app it reached once this arrives.
public struct NectoHandshakeHello: Sendable, Hashable, Codable {
    public let protocolVersion: Int
    public let appBundleID: String
    public let appName: String
    public let appVersion: String
    public let deviceName: String
    /// As the device reports it, such as `18.2`. Shown so two identically named
    /// devices can be told apart.
    public let osVersion: String
    public let sdkVersion: String
    /// PNG of the app icon, so the Mac can show the app as the user knows it rather
    /// than a placeholder. Encoded as base64 by `Codable`, and absent when the app has
    /// no icon to read.
    public let appIcon: Data?
    /// The simulator's UDID when the app runs in one, absent on a physical device.
    /// Simulators share the Mac's loopback, so without this every simulator would be
    /// the same device.
    public let simulatorID: String?

    public init(
        protocolVersion: Int = NectoProtocol.currentVersion,
        appBundleID: String,
        appName: String,
        appVersion: String = "",
        deviceName: String,
        osVersion: String = "",
        sdkVersion: String,
        appIcon: Data? = nil,
        simulatorID: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.appBundleID = appBundleID
        self.appName = appName
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.osVersion = osVersion
        self.simulatorID = simulatorID
        self.sdkVersion = sdkVersion
        self.appIcon = appIcon
    }
}

/// The Mac's answer to a hello.
public struct NectoHandshakeAck: Sendable, Hashable, Codable {
    public enum Rejection: String, Sendable, Codable {
        case unsupportedProtocolVersion
        case missingAppIdentity
    }

    public let accepted: Bool
    public let rejection: Rejection?
    public let hostProtocolVersion: Int

    public init(accepted: Bool, rejection: Rejection? = nil) {
        self.accepted = accepted
        self.rejection = rejection
        hostProtocolVersion = NectoProtocol.currentVersion
    }

    /// Decides whether a hello can start a session.
    ///
    /// Necto speaks one protocol version. A mismatch fails the connection rather than
    /// negotiating, so a stale app cannot half work against a newer host.
    public static func evaluate(_ hello: NectoHandshakeHello) -> NectoHandshakeAck {
        guard NectoProtocol.isSupported(version: hello.protocolVersion) else {
            return NectoHandshakeAck(accepted: false, rejection: .unsupportedProtocolVersion)
        }
        guard !hello.appBundleID.isEmpty else {
            return NectoHandshakeAck(accepted: false, rejection: .missingAppIdentity)
        }
        return NectoHandshakeAck(accepted: true)
    }
}
