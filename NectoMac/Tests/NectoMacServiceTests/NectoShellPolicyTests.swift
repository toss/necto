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

@Suite("Shell policy review")
struct NectoShellPolicyReviewTests {
    @Test("authorization alone requests shell access without offering command approval")
    func reviewsAuthorizationWithoutExecution() async {
        let policy = NectoShellPolicy()
        let authorization = NectoShellOperationInterpreter.Operation(
            operationID: "shell.request",
            description: "Ask for shell access",
            binding: .init(name: "necto.desktop.shell.authorization.request", version: 1),
            kind: .once,
            interpretation: .authorizationRequest
        )

        let noShell = await policy.review(interpretedOperations: [])
        #expect(!noShell.requestsShellAccess)
        #expect(!noShell.canApproveDeclaredCommands)

        let authorizationOnly = await policy.review(interpretedOperations: [authorization])
        #expect(authorizationOnly.requestsShellAccess)
        #expect(authorizationOnly.requestedOperations == [authorization])
        #expect(!authorizationOnly.canApproveDeclaredCommands)

        let withExecution = await policy.review(interpretedOperations: [authorization, execution()])
        #expect(withExecution.canApproveDeclaredCommands)
    }

    @Test("incomplete execution declarations stay visible but disable command approval")
    func requiresCompleteExecutionDeclarations() async {
        let policy = NectoShellPolicy()
        let incompleteOperations = [
            execution(id: "shell.dynamic", interpretation: .execute(.unavailable(.enumNotDeclared))),
            execution(id: "shell.undocumented", description: " \n\t"),
            execution(id: "shell.empty-enum", interpretation: .execute(.values([]))),
        ]

        for incomplete in incompleteOperations {
            let operations = [execution(), incomplete]
            let review = await policy.review(interpretedOperations: operations)
            #expect(review.requestsShellAccess)
            #expect(review.requestedOperations == operations)
            #expect(!review.canApproveDeclaredCommands)
        }
    }

    @Test("invalid commands stay visible but disable command approval", arguments: [" \n\t", "git\0status"])
    func rejectsInvalidCommands(command: String) async {
        let policy = NectoShellPolicy()
        let operation = execution(interpretation: .execute(.values(["pwd", command])))
        let review = await policy.review(interpretedOperations: [operation])

        #expect(review.requestsShellAccess)
        #expect(review.requestedOperations == [operation])
        #expect(!review.canApproveDeclaredCommands)
    }

    @Test("an unsupported contract stays visible and blocks approval beside a valid declaration")
    func refusesMixedSupportedAndUnsupportedContracts() async {
        let policy = NectoShellPolicy()
        let supported = execution()
        let unsupported = execution(id: "shell.future", version: 3, interpretation: .unsupportedContract)
        let operations = [supported, unsupported]

        let review = await policy.review(interpretedOperations: operations)

        #expect(review.requestsShellAccess)
        #expect(review.requestedOperations == operations)
        #expect(!review.canApproveDeclaredCommands)
    }

    @Test("review reports only the matching saved grant and leaves shell decisions unchanged")
    func readsGrantWithoutChangingPolicy() async {
        let grant = NectoShellGrant(
            principal: notes, level: .commandApproval, approvedCommands: ["git status"], contentIdentity: "previous"
        )
        let policy = NectoShellPolicy(snapshot: .init(grants: [grant]))
        let snapshot = await policy.snapshot()
        let operations = [execution()]
        let replacement = NectoPluginPrincipal(pluginID: notes.pluginID, sourceIdentity: "/plugins/replacement")

        let existing = await policy.review(interpretedOperations: operations, for: notes)
        let differentSource = await policy.review(interpretedOperations: operations, for: replacement)
        let newCandidate = await policy.review(interpretedOperations: operations)

        #expect(existing.currentGrant == grant)
        #expect(existing.effectiveAccessLevel == .commandApproval)
        #expect(!existing.isFullAccessEnabled)
        #expect(differentSource.currentGrant == nil)
        #expect(differentSource.effectiveAccessLevel == .protected)
        #expect(newCandidate.currentGrant == nil)
        #expect(newCandidate.effectiveAccessLevel == .protected)
        #expect(newCandidate.canApproveDeclaredCommands)
        let afterReview = await policy.snapshot()
        #expect(afterReview.grants == snapshot.grants)
        #expect(afterReview.isFullAccessEnabled == snapshot.isFullAccessEnabled)
        #expect(await policy.allows("git status", for: notes))
        #expect(await policy.allows("pwd", for: notes) == false)
        #expect(await policy.allows("git status", for: replacement) == false)
    }

    @Test("global full access overrides the effective level while preserving the saved grant")
    func reportsGlobalOverride() async {
        let grant = NectoShellGrant(principal: notes, level: .commandApproval, approvedCommands: ["git status"])
        let policy = NectoShellPolicy(snapshot: .init(isFullAccessEnabled: true, grants: [grant]))
        let operations = [execution()]

        let existing = await policy.review(interpretedOperations: operations, for: notes)
        let newCandidate = await policy.review(interpretedOperations: operations)

        #expect(existing.isFullAccessEnabled)
        #expect(existing.effectiveAccessLevel == .fullAccess)
        #expect(existing.currentGrant == grant)
        #expect(newCandidate.isFullAccessEnabled)
        #expect(newCandidate.effectiveAccessLevel == .fullAccess)
        #expect(newCandidate.currentGrant == nil)
        #expect(await policy.snapshot() == .init(isFullAccessEnabled: true, grants: [grant]))
    }

    private func execution(
        id: String = "shell.run",
        version: Int = 1,
        description: String = "Read local diagnostics",
        interpretation: NectoShellOperationInterpreter.Interpretation = .execute(.values(["pwd"]))
    ) -> NectoShellOperationInterpreter.Operation {
        NectoShellOperationInterpreter.Operation(
            operationID: id,
            description: description,
            binding: .init(name: "necto.desktop.shell.execute", version: version),
            kind: .once,
            interpretation: interpretation
        )
    }
}
