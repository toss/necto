//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Testing
@testable import NectoMacService

@Suite("Event collection policy")
struct NectoEventCollectionPolicyTests {
    @Test("all plugin IDs and host activity are included by default")
    func includesByDefault() {
        let policy = NectoEventCollectionPolicy()
        #expect(policy.allowsCollection(from: "records"))
        #expect(policy.allowsCollection(from: "new-plugin"))
        #expect(policy.allowsCollection(from: nil))
    }

    @Test("exclusions use the plugin ID without excluding unrelated host activity")
    func excludesPluginIDs() {
        let policy = NectoEventCollectionPolicy(excludedPluginIDs: ["records"])
        #expect(!policy.allowsCollection(from: "records"))
        #expect(policy.allowsCollection(from: "notes"))
        #expect(policy.allowsCollection(from: "new-plugin"))
        #expect(policy.allowsCollection(from: nil))
    }

    @Test("including one plugin preserves other exclusions")
    func includingPreservesOtherExclusions() {
        var policy = NectoEventCollectionPolicy(excludedPluginIDs: ["records", "notes"])
        policy.excludedPluginIDs.remove("records")
        #expect(policy.allowsCollection(from: "records"))
        #expect(!policy.allowsCollection(from: "notes"))
    }
}
