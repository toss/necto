//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// The real routing destination: one connected app.
///
/// Several apps can attach to the same device, so a device id alone does not
/// identify a target.
public struct NectoTarget: Sendable, Hashable, Codable {
    public let deviceID: String
    public let appBundleID: String

    public init(deviceID: String, appBundleID: String) {
        self.deviceID = deviceID
        self.appBundleID = appBundleID
    }
}

/// Target information exposed to a plugin.
///
/// Plugins cannot address a target by raw device id. They only use the
/// `targetHandle` the host issues per principal.
public struct NectoTargetInfo: Sendable, Hashable, Codable {
    public let targetHandle: String
    /// Compatibility alias for `targetHandle`, not a hardware device identifier.
    public let deviceID: String
    public let appBundleID: String
    public let name: String?
    public let appName: String?

    public init(
        targetHandle: String,
        deviceID: String? = nil,
        appBundleID: String,
        name: String? = nil,
        appName: String? = nil
    ) {
        self.targetHandle = targetHandle
        // Keep the serialized field without exposing the legacy raw identifier.
        self.deviceID = targetHandle
        self.appBundleID = appBundleID
        self.name = name
        self.appName = appName
    }
}
