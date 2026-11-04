//
//  Copyright (c) 2026 Viva Republica, Inc.
//

/// Plugin IDs excluded from collection by the registered exporter.
public struct NectoEventCollectionPolicy: Sendable, Equatable {
    /// Exclusions apply to a plugin ID across apps and plugin versions.
    public var excludedPluginIDs: Set<String>

    public init(
        excludedPluginIDs: Set<String> = []
    ) {
        self.excludedPluginIDs = excludedPluginIDs
    }

    public func allowsCollection(from pluginID: String?) -> Bool {
        guard let pluginID else { return true }
        return !excludedPluginIDs.contains(pluginID)
    }
}
