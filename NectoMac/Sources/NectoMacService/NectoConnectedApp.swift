//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// An app that completed the handshake and is holding a session open.
public struct NectoConnectedApp: Sendable, Hashable, Identifiable {
    public enum Connection: String, Sendable, Hashable {
        case usb
        case simulator
        case androidDevice
        case androidEmulator

        public var isEmulator: Bool { self == .simulator || self == .androidEmulator }
        public var osName: String {
            self == .androidDevice || self == .androidEmulator ? "Android" : "iOS"
        }
    }

    public let target: NectoTarget
    public let deviceName: String
    public let osVersion: String
    public let appName: String
    public let appVersion: String
    public let sdkVersion: String
    public let connection: Connection
    /// PNG the app sent at handshake, when it had one.
    public let appIcon: Data?

    /// Matches the composite id used elsewhere: a device alone does not identify a target.
    public var id: String { Self.id(for: target) }

    public static func id(for target: NectoTarget) -> String {
        "\(target.deviceID)|\(target.appBundleID)"
    }

    public var appBundleID: String { target.appBundleID }

    public init(
        target: NectoTarget,
        deviceName: String,
        osVersion: String = "",
        appName: String,
        appVersion: String = "",
        sdkVersion: String,
        connection: Connection,
        appIcon: Data? = nil
    ) {
        self.target = target
        self.deviceName = deviceName
        self.osVersion = osVersion
        self.appName = appName
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
        self.connection = connection
        self.appIcon = appIcon
    }
}
