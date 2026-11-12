//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoModel
import Testing

@Suite("Shell approval controller", .timeLimit(.minutes(1)))
@MainActor
struct NectoShellAccessControllerTests {
    private let a = NectoPluginPrincipal(pluginID: "com.example.a", sourceIdentity: "local:a")
    private let b = NectoPluginPrincipal(pluginID: "com.example.b", sourceIdentity: "local:b")

    private func controller() -> NectoShellAccessController {
        NectoShellAccessController(snapshot: .init(), saveSnapshot: { _ in })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for approval state")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("Installation rollback restores the prior grant and preserves unrelated policy changes")
    func rollsBackOnlyInstallationGrant() async throws {
        let original = NectoShellGrant(
            principal: a, level: .commandApproval, approvedCommands: ["echo old"], contentIdentity: "old content"
        )
        let initial = NectoShellPolicySnapshot(grants: [original])
        var saved: [NectoShellPolicySnapshot] = []
        let controller = NectoShellAccessController(snapshot: initial) { saved.append($0) }
        let noShell = await controller.policy.review(interpretedOperations: [], for: a)

        #expect(try await controller.applyInstallationChoice(review: noShell, level: nil, for: a) == nil)
        #expect(saved.isEmpty)

        let review = await controller.policy.review(interpretedOperations: shellOperations, for: a)
        let applied = try await controller.applyInstallationChoice(review: review, level: .fullAccess, for: a)
        let change = try #require(applied)
        #expect(saved.count == 1)
        #expect(saved.last?.grants.first?.level == .fullAccess)
        #expect(controller.snapshot == saved.last)

        await controller.setFullAccessEnabled(true)
        try await controller.approve("echo B", for: b)
        await controller.rollbackInstallationChoice(change)

        let expected = NectoShellPolicySnapshot(isFullAccessEnabled: true, grants: [
            original, NectoShellGrant(principal: b, level: .commandApproval, approvedCommands: ["echo B"]),
        ])
        #expect(saved.last == expected)
        #expect(controller.snapshot == expected)
        #expect(await controller.policy.snapshot() == expected)
    }

    @Test("Installation rollback removes a new grant only while that grant is unchanged",
          arguments: [false, true])
    func rollsBackNewGrant(keepLaterChange: Bool) async throws {
        var saved: [NectoShellPolicySnapshot] = []
        let controller = NectoShellAccessController(snapshot: .init()) { saved.append($0) }
        let review = await controller.policy.review(interpretedOperations: shellOperations)
        let applied = try await controller.applyInstallationChoice(review: review, level: .fullAccess, for: a)
        let change = try #require(applied)
        if keepLaterChange {
            await controller.setAccessLevel(.protected, for: a)
        }

        await controller.rollbackInstallationChoice(change)

        let expected = NectoShellPolicySnapshot(grants: keepLaterChange ? [NectoShellGrant(principal: a)] : [])
        #expect(saved.count == 2)
        #expect(saved.last == expected)
        #expect(controller.snapshot == expected)
        #expect(await controller.policy.snapshot() == expected)
    }

    @Test("Cancelled dialog actions cannot approve or dismiss the next request", arguments: 0..<20)
    func cancelledDialogActions(_ iteration: Int) async throws {
        let controller = controller()
        let first = Task { await controller.requestApproval(.init(id: "shared", principal: a, commands: ["echo A"])) }
        defer { first.cancel() }
        try await waitUntil { controller.pendingApproval != nil }
        let displayedA = try #require(controller.pendingApproval).id
        var queued = false
        let second = Task {
            queued = true
            return await controller.requestApproval(.init(id: "shared", principal: b, commands: [], access: .fullAccess))
        }
        defer { second.cancel() }
        try await waitUntil { queued }
        controller.cancelRequests(for: a)
        #expect(controller.pendingApproval?.request.principal == b)
        let displayedB = try #require(controller.pendingApproval).id
        #expect(displayedA != displayedB, "Caller-supplied IDs must not identify dialogs")
        controller.approvePendingRequest(id: displayedA)
        controller.denyPendingRequest(id: displayedA)
        #expect(controller.pendingApproval?.id == displayedB)
        #expect(await controller.policy.access(for: b).level == .protected)
        controller.approvePendingRequest(id: displayedB)
        controller.approvePendingRequest(id: displayedB)
        #expect(!(await first.value).approved)
        #expect((await second.value).approved)
        #expect(await controller.policy.access(for: a).level == .protected)
        #expect(await controller.policy.access(for: b).level == .fullAccess)
    }

    @Test("Denial preserves existing exact-command grants")
    func denialPreservesExistingGrants() async throws {
        var saved = NectoShellPolicySnapshot()
        let controller = NectoShellAccessController(snapshot: saved) { saved = $0 }
        try await controller.approve("echo existing", for: a)
        let partial = Task {
            await controller.requestApproval(.init(principal: a, commands: ["echo existing", "echo new"]))
        }
        defer { partial.cancel() }
        try await waitUntil { controller.pendingApproval != nil }
        let pending = try #require(controller.pendingApproval)
        #expect(pending.request.commands == ["echo new"])
        controller.denyPendingRequest(id: pending.id)
        let denied = await partial.value
        #expect(!denied.approved)
        #expect(denied.approvedCommands == ["echo existing"])
        #expect(!(await controller.policy.allows("echo new", for: a)))
        #expect(saved.grants.first { $0.principal == a }?.approvedCommands == ["echo existing"])
    }

    @Test("Task cancellation distinguishes queued and visible requests with the same caller ID")
    func taskCancellationIsScoped() async throws {
        let controller = controller()
        let visible = Task { await controller.requestApproval(.init(id: "duplicate", principal: a, commands: ["echo A"])) }
        defer { visible.cancel() }
        try await waitUntil { controller.pendingApproval != nil }
        let visibleID = try #require(controller.pendingApproval).id
        var queued = false
        let waiting = Task {
            queued = true
            return await controller.requestApproval(.init(id: "duplicate", principal: b, commands: ["echo B"]))
        }
        defer { waiting.cancel() }
        try await waitUntil { queued }
        waiting.cancel()
        #expect(!(await waiting.value).approved)
        #expect(controller.pendingApproval?.id == visibleID)
        visible.cancel()
        #expect(!(await visible.value).approved)
        #expect(controller.pendingApproval == nil)
        controller.approvePendingRequest(id: visibleID)
        #expect(!(await controller.policy.allows("echo A", for: a)))
    }

    @Test("Command approval persists only the approved principal's grant")
    func commandApprovalIsScoped() async throws {
        var saved = NectoShellPolicySnapshot()
        let controller = NectoShellAccessController(snapshot: saved) { saved = $0 }
        let command = Task { await controller.requestApproval(.init(principal: a, commands: ["echo A"])) }
        defer { command.cancel() }
        try await waitUntil { controller.pendingApproval != nil }
        let commandID = try #require(controller.pendingApproval).id
        controller.approvePendingRequest(id: commandID)
        #expect((await command.value).approved)
        #expect(await controller.policy.allows("echo A", for: a))
        #expect(!(await controller.policy.allows("echo A", for: b)))
        #expect(saved.grants.count == 1)
        #expect(saved.grants.first?.principal == a)
        #expect(saved.grants.first?.approvedCommands == ["echo A"])
    }

    @Test("Repeated actions after approval cannot affect the next dialog")
    func repeatedActionsAreIgnored() async throws {
        let controller = controller()
        let first = Task { await controller.requestApproval(.init(principal: a, commands: ["echo A"])) }
        defer { first.cancel() }
        try await waitUntil { controller.pendingApproval != nil }
        let previousID = try #require(controller.pendingApproval).id
        var queued = false
        let next = Task {
            queued = true
            return await controller.requestApproval(.init(principal: b, commands: [], access: .fullAccess))
        }
        defer { next.cancel() }
        try await waitUntil { queued }
        controller.approvePendingRequest(id: previousID)
        controller.approvePendingRequest(id: previousID)
        #expect((await first.value).approved)
        try await waitUntil { controller.pendingApproval?.request.principal == b }
        let nextID = try #require(controller.pendingApproval).id
        controller.approvePendingRequest(id: previousID)
        controller.denyPendingRequest(id: previousID)
        #expect(controller.pendingApproval?.id == nextID)
        controller.denyPendingRequest(id: nextID)
        #expect(!(await next.value).approved)
        #expect(await controller.policy.access(for: b).level == .protected)
    }

    private var shellOperations: [NectoShellOperationInterpreter.Operation] {
        let descriptor = NectoShellContracts.authorization
        return NectoShellOperationInterpreter.interpret(operations: [
            NectoOperation(
                id: "shell.request",
                title: "Request shell access",
                description: "Request shell access to read diagnostics.",
                kind: descriptor.kind,
                binding: descriptor.binding,
                inputSchema: descriptor.inputSchema,
                outputSchema: descriptor.outputSchema,
                timeoutMs: 5_000
            ),
        ])
    }
}
