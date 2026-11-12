//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// Host-owned identity and plugin-ID exclusions. Installing or removing an
/// exporter does not reset either value.
@MainActor
public final class NectoEventPreferences {
    private let defaults: UserDefaults
    private static let installationKey = "eventInstallationID"
    private static let exclusionsKey = "eventExcludedPluginIDs"

    public let installationID: String

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.installationKey), !saved.isEmpty {
            installationID = saved
        } else {
            installationID = UUID().uuidString
            defaults.set(installationID, forKey: Self.installationKey)
        }
    }

    public var policy: NectoEventCollectionPolicy {
        get {
            NectoEventCollectionPolicy(
                excludedPluginIDs: Set(defaults.stringArray(forKey: Self.exclusionsKey) ?? [])
            )
        }
        set {
            defaults.set(newValue.excludedPluginIDs.sorted(), forKey: Self.exclusionsKey)
        }
    }
}
