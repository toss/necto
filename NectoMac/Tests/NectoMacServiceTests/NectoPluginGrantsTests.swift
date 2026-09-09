//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Testing

@testable import NectoMacService

private let network = NectoPluginPrincipal(pluginID: "network-logger", sourceIdentity: "builtin")
private let sideloaded = NectoPluginPrincipal(pluginID: "network-logger", sourceIdentity: "/tmp/elsewhere")

@Suite("Plugin grants")
struct NectoPluginGrantsTests {
    @Test("nothing is granted until someone grants it")
    func startsEmpty() {
        let grants = NectoPluginGrants()
        #expect(grants.bridges(for: network).isEmpty)
    }

    @Test("remembers what was approved")
    func remembers() {
        var grants = NectoPluginGrants()
        grants.grant(["necto.device.network-records.list@1"], to: network)

        #expect(grants.bridges(for: network) == ["necto.device.network-records.list@1"])
    }

    /// The same id from another source is another plugin. Inheriting an approval across
    /// that line is how a sideloaded copy would arrive pre-trusted.
    @Test("keeps the same id from a different source apart")
    func principalsAreSeparate() {
        var grants = NectoPluginGrants()
        grants.grant(["necto.device.network-records.list@1"], to: network)

        #expect(grants.bridges(for: sideloaded).isEmpty)
    }

    // MARK: What still needs asking

    @Test("says nothing is outstanding when everything was approved")
    func nothingOutstanding() {
        var grants = NectoPluginGrants()
        grants.grant(["a", "b"], to: network)

        #expect(grants.unapproved(["a", "b"], for: network).isEmpty)
    }

    /// An update that widens what a plugin wants has to be approved again for the new
    /// part, or a plugin grows powers between versions without anyone deciding.
    @Test("asks again only for what is new")
    func widenedRequestNeedsApproval() {
        var grants = NectoPluginGrants()
        grants.grant(["a"], to: network)

        #expect(grants.unapproved(["a", "b"], for: network) == ["b"])
    }

    @Test("a plugin that asks for less does not need asking again")
    func narrowedRequestIsFine() {
        var grants = NectoPluginGrants()
        grants.grant(["a", "b"], to: network)

        #expect(grants.unapproved(["a"], for: network).isEmpty)
    }

    @Test("revoking takes everything back")
    func revoke() {
        var grants = NectoPluginGrants()
        grants.grant(["a"], to: network)

        grants.revoke(network)

        #expect(grants.bridges(for: network).isEmpty)
        #expect(grants.unapproved(["a"], for: network) == ["a"])
    }

    @Test("survives being written out and read back")
    func roundTrips() {
        var grants = NectoPluginGrants()
        grants.grant(["b", "a"], to: network)
        grants.grant(["c"], to: sideloaded)

        let restored = NectoPluginGrants(stored: grants.stored)

        #expect(restored.bridges(for: network) == ["a", "b"])
        #expect(restored.bridges(for: sideloaded) == ["c"])
    }
}
