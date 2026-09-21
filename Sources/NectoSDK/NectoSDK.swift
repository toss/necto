//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoTransport
import Foundation

/// The entry point embedded in a connected app.
///
/// Opens a port for Necto, answers the handshake, and carries plugin messages in both
/// directions. That is the whole job: the SDK is a bridge, and every permission an
/// app exposes arrives as an `NectoPluginable` the app registers. Nothing here knows what
/// a network request, a view tree or a feature flag is.
///
/// ```swift
/// NectoSDK.register(NectoNetworkPlugin())
/// NectoSDK.start()
/// print(NectoSDK.status)
/// ```
public enum NectoSDK {
    public static let version = "0.1.0"

    public enum Status: Sendable, Equatable {
        case stopped
        case listening(port: UInt16)
        case connected(appBundleID: String)
        case failed(String)
    }

    public static var status: Status { runtime.status }

    /// The current connection state followed by later transitions.
    public static var statusUpdates: AsyncStream<Status> { runtime.statusUpdates() }

    /// Adds a plugin, at any point. One added while a host is attached joins that
    /// session rather than waiting for the next one. Duplicate IDs assert in debug
    /// and are rejected in every build. Unregister first to intentionally replace one.
    public static func register(_ plugin: any NectoPluginable) {
        let registered = runtime.register(plugin)
        assert(registered, "Plugin '\(plugin.id)' duplicates a registered ID or bridge contract. Use unique IDs and contract names, or unregister the previous plugin before replacing it.")
    }

    /// Takes a plugin away and tells any attached host that it now offers nothing.
    public static func unregister(id: String) {
        runtime.unregister(id: id)
    }

    public static var plugins: [any NectoPluginable] { runtime.plugins }

    /// Starts listening. Safe to call at app start up; it does not block the caller.
    public static func start(port: UInt16 = NectoDeviceListener.defaultPort) {
        runtime.start(port: port)
    }

    public static func stop() {
        runtime.stop()
    }

    /// The wire protocol version this SDK speaks.
    public static var protocolVersion: Int { NectoProtocol.currentVersion }

    private static let runtime = NectoSDKRuntime()
}
