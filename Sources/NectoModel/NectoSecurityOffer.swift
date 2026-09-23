//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// Public discovery metadata used only to select a host credential and show denied apps.
/// None of these fields proves the device app's identity.
public struct NectoSecurityOffer: Codable, Sendable, Equatable {
    public let type: String
    public let version: Int
    public let appBundleID: String
    public let appName: String
    public let deviceName: String
    public let osVersion: String
    public let simulatorID: String?

    public init(hello: NectoHandshakeHello) {
        type = "necto.security"
        version = 1
        appBundleID = hello.appBundleID
        appName = hello.appName
        deviceName = hello.deviceName
        osVersion = hello.osVersion
        simulatorID = hello.simulatorID
    }

    public var isSupported: Bool {
        type == "necto.security" && version == 1 && !appBundleID.isEmpty
    }
}
