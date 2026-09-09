//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// What a person actually agreed to, per plugin.
///
/// A plugin is installed because someone read the bridges it binds and said yes, so
/// this is what they read. Kept apart from the manifest on purpose: a manifest says
/// what a plugin *asks* for and is written by whoever wrote the plugin, and reading
/// the answer off the question is how a plugin ends up agreeing with itself.
///
/// Held as bridge identities — `necto.device.events.list@1` — because that is the whole
/// declaration. There is no permission name in between to say something other than
/// what is really wanted.
public struct NectoPluginGrants: Sendable, Equatable {
    /// Keyed by principal rather than by id: the same id from a different source is a
    /// different plugin, and must not inherit an approval given to the other one.
    private var granted: [String: Set<String>]

    public init(granted: [String: Set<String>] = [:]) {
        self.granted = granted
    }

    public func bridges(for principal: NectoPluginPrincipal) -> Set<String> {
        granted[Self.key(principal)] ?? []
    }

    public mutating func grant(_ bridges: Set<String>, to principal: NectoPluginPrincipal) {
        granted[Self.key(principal)] = bridges
    }

    public mutating func revoke(_ principal: NectoPluginPrincipal) {
        granted.removeValue(forKey: Self.key(principal))
    }

    /// What a plugin is asking for that nobody has agreed to yet.
    ///
    /// An update that widens what a plugin wants has to be approved again for the new
    /// part. Letting an existing grant cover it is how a plugin grows powers quietly.
    /// A bridge whose version moved counts as new, because a bridge that changed enough
    /// to renumber is not the one that was agreed to.
    public func unapproved(
        _ wanted: Set<String>,
        for principal: NectoPluginPrincipal
    ) -> Set<String> {
        wanted.subtracting(bridges(for: principal))
    }

    private static func key(_ principal: NectoPluginPrincipal) -> String {
        "\(principal.pluginID)\u{1F}\(principal.sourceIdentity)"
    }

    // MARK: Storage

    public var stored: [String: [String]] {
        granted.mapValues { $0.sorted() }
    }

    public init(stored: [String: [String]]) {
        granted = stored.mapValues(Set.init)
    }
}
