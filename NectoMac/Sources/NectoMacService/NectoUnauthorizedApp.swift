//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// A discovered app with no admitted debugging session or plugin permissions.
public struct NectoUnauthorizedApp: Sendable, Hashable, Identifiable {
    public enum Reason: String, Sendable, Codable {
        case missingKey
        case rejectedKey
        case credentialUnavailable
    }

    public let target: NectoTarget
    public let appName: String
    public let deviceName: String
    public let osVersion: String
    public let connection: NectoConnectedApp.Connection
    public let reason: Reason
    public var id: String { NectoConnectedApp.id(for: target) }
    public var appBundleID: String { target.appBundleID }

    public init(target: NectoTarget, appName: String, deviceName: String, osVersion: String = "", connection: NectoConnectedApp.Connection, reason: Reason) {
        self.target = target
        self.appName = appName
        self.deviceName = deviceName
        self.osVersion = osVersion
        self.connection = connection
        self.reason = reason
    }
}
