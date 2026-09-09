//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Testing

@testable import NectoMacService

private let notes = NectoPluginPrincipal(pluginID: "target-notes", sourceIdentity: "/plugins/target-notes")
private let other = NectoPluginPrincipal(pluginID: "other", sourceIdentity: "/plugins/other")

@Suite("Shell policy")
struct NectoShellPolicyTests {
    @Test("starts protected")
    func startsProtected() async {
        let policy = NectoShellPolicy()

        #expect(await policy.access(for: notes).level == .protected)
        #expect(await policy.allows("git status", for: notes) == false)
    }

    @Test("command approval matches the exact command and principal")
    func exactApproval() async throws {
        let policy = NectoShellPolicy()
        try await policy.approve("git status --short", for: notes)

        #expect(await policy.allows("git status --short", for: notes))
        #expect(await policy.allows("git status", for: notes) == false)
        #expect(await policy.allows("git status --short", for: other) == false)
    }

    @Test("plugin full access does not grant another plugin")
    func pluginFullAccessIsScoped() async {
        let policy = NectoShellPolicy()
        await policy.setAccessLevel(.fullAccess, for: notes)

        #expect(await policy.allows("anything", for: notes))
        #expect(await policy.allows("anything", for: other) == false)
    }

    @Test("global full access is an override and preserves plugin settings")
    func globalOverride() async throws {
        let policy = NectoShellPolicy()
        try await policy.approve("git status", for: notes)
        await policy.setFullAccessEnabled(true)

        #expect(await policy.allows("anything", for: other))

        await policy.setFullAccessEnabled(false)
        #expect(await policy.allows("git status", for: notes))
        #expect(await policy.allows("anything", for: other) == false)
    }

    @Test("snapshot round trips all decisions")
    func snapshotRoundTrip() async throws {
        let policy = NectoShellPolicy()
        try await policy.approve("xcrun simctl list devices", for: notes)
        await policy.setAccessLevel(.fullAccess, for: other)

        let restored = NectoShellPolicy(snapshot: await policy.snapshot())

        #expect(await restored.allows("xcrun simctl list devices", for: notes))
        #expect(await restored.allows("anything", for: other))
    }

    @Test("revoking commands does not change another principal")
    func revokesCommands() async throws {
        let policy = NectoShellPolicy()
        try await policy.approve("git status", for: notes)
        try await policy.approve("git status", for: other)

        await policy.revoke("git status", for: notes)

        #expect(await policy.allows("git status", for: notes) == false)
        #expect(await policy.allows("git status", for: other))
    }

    @Test("rejects empty commands")
    func rejectsEmpty() async {
        let policy = NectoShellPolicy()
        let error = await #expect(throws: NectoBridgeError.self) {
            try await policy.approve("   ", for: notes)
        }
        #expect(error?.code == .invalidInput)
    }

    @Test("trusted updates preserve access for the same principal")
    func contentChangePreservesAccess() async throws {
        let policy = NectoShellPolicy()
        await policy.registerContentIdentity("first", for: notes)
        try await policy.approve("git status", for: notes)

        await policy.registerContentIdentity("second", for: notes)

        #expect(await policy.access(for: notes).level == .commandApproval)
        #expect(await policy.allows("git status", for: notes))
        #expect(await policy.access(for: notes).contentIdentity == "second")
        await policy.setAccessLevel(.fullAccess, for: notes)
        await policy.registerContentIdentity("third", for: notes)
        #expect(await policy.allows("anything", for: notes))
        #expect(await policy.allows("anything", for: other) == false)
    }
}
