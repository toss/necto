//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing
@testable import NectoMacService

@Suite("Event preferences")
@MainActor
struct NectoEventPreferencesTests {
    @Test("the host installation ID is generated once and restored on restart")
    func restoresInstallationID() throws {
        let domain = "NectoEventPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let first = NectoEventPreferences(defaults: defaults)
        #expect(UUID(uuidString: first.installationID) != nil)
        let restarted = NectoEventPreferences(defaults: try #require(UserDefaults(suiteName: domain)))
        #expect(restarted.installationID == first.installationID)
    }

    @Test("plugin ID exclusions survive restart and including one preserves the others")
    func restoresExclusions() throws {
        let domain = "NectoEventPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let preferences = NectoEventPreferences(defaults: defaults)
        preferences.policy = .init(excludedPluginIDs: ["com.example.records", "com.example.absent"])
        let restored = NectoEventPreferences(defaults: defaults)
        #expect(!restored.policy.allowsCollection(from: "com.example.records"))
        #expect(!restored.policy.allowsCollection(from: "com.example.absent"))
        #expect(restored.policy.allowsCollection(from: "com.example.new-plugin"))
        #expect(restored.policy.allowsCollection(from: nil))

        var changed = restored.policy
        changed.excludedPluginIDs.remove("com.example.records")
        restored.policy = changed
        let restarted = NectoEventPreferences(defaults: defaults)
        #expect(restarted.policy.allowsCollection(from: "com.example.records"))
        #expect(!restarted.policy.allowsCollection(from: "com.example.absent"))
        #expect(restarted.installationID == preferences.installationID)
    }
}
