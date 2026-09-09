//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// Issues the opaque handles plugins use to name a connected app.
///
/// A plugin never sees a device id. It receives a handle, and only the handle is
/// accepted back, which means a plugin cannot address an app it was never shown.
/// Handles are per principal, so two plugins looking at the same app hold different
/// values and neither can use the other's.
///
/// They last as long as the host session. Nothing persists them, so a handle from a
/// previous run is simply unknown.
public actor NectoTargetHandles {
    private var issued: [NectoPluginPrincipal: [NectoTarget: String]] = [:]
    private var resolved: [NectoPluginPrincipal: [String: NectoTarget]] = [:]

    public init() {}

    /// Stable for a given principal and target, so a plugin can compare handles it
    /// received at different times.
    public func handle(for target: NectoTarget, principal: NectoPluginPrincipal) -> String {
        if let existing = issued[principal]?[target] { return existing }

        let handle = UUID().uuidString
        issued[principal, default: [:]][target] = handle
        resolved[principal, default: [:]][handle] = target
        return handle
    }

    /// The target a handle names, or nil when this principal was never given it.
    public func target(for handle: String, principal: NectoPluginPrincipal) -> NectoTarget? {
        resolved[principal]?[handle]
    }

    public func forget(principal: NectoPluginPrincipal) {
        issued.removeValue(forKey: principal)
        resolved.removeValue(forKey: principal)
    }
}
