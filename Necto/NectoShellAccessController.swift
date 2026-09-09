//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoMacService
import Foundation
import Observation

@MainActor
@Observable
final class NectoShellAccessController: NectoShellApprovalRequesting {
    struct PendingApproval: Identifiable {
        // Caller correlation IDs can repeat; dialog actions use a host-issued identity.
        let id: UUID
        let request: NectoShellApprovalRequest
    }

    private struct QueuedApproval {
        let id: UUID
        let request: NectoShellApprovalRequest
        let alreadyApproved: Set<String>
        let continuation: CheckedContinuation<NectoShellApprovalResult, Never>
    }

    let policy: NectoShellPolicy
    private(set) var snapshot: NectoShellPolicySnapshot
    private(set) var pendingApproval: PendingApproval?
    private var approvals: [QueuedApproval] = []
    private let saveSnapshot: (NectoShellPolicySnapshot) -> Void

    init(snapshot: NectoShellPolicySnapshot, saveSnapshot: @escaping (NectoShellPolicySnapshot) -> Void) {
        self.snapshot = snapshot
        self.saveSnapshot = saveSnapshot
        policy = NectoShellPolicy(snapshot: snapshot)
    }

    var isFullAccessEnabled: Bool { snapshot.isFullAccessEnabled }

    func grant(for principal: NectoPluginPrincipal) -> NectoShellGrant {
        snapshot.grants.first { $0.principal == principal }
            ?? NectoShellGrant(principal: principal)
    }

    func setFullAccessEnabled(_ enabled: Bool) async {
        persist(await policy.setFullAccessEnabled(enabled))
    }

    func setAccessLevel(_ level: NectoShellAccessLevel, for principal: NectoPluginPrincipal) async {
        persist(await policy.setAccessLevel(level, for: principal))
    }

    func registerContentIdentity(_ identity: String, for principal: NectoPluginPrincipal) async {
        persist(await policy.registerContentIdentity(identity, for: principal))
    }

    func approve(_ command: String, for principal: NectoPluginPrincipal) async throws {
        persist(try await policy.approve(command, for: principal))
    }

    func revoke(_ command: String, for principal: NectoPluginPrincipal) async {
        persist(await policy.revoke(command, for: principal))
    }

    func revokeAll(for principal: NectoPluginPrincipal) async {
        persist(await policy.revokeAll(for: principal))
    }

    func forget(_ principal: NectoPluginPrincipal) async {
        persist(await policy.forget(principal))
    }

    func requestApproval(_ request: NectoShellApprovalRequest) async -> NectoShellApprovalResult {
        guard !Task.isCancelled else {
            return NectoShellApprovalResult(approved: false, access: request.access)
        }

        let requested = Set(request.commands)
        let grant = grant(for: request.principal)
        if snapshot.isFullAccessEnabled || grant.level == .fullAccess {
            return NectoShellApprovalResult(
                approved: true,
                access: request.access,
                approvedCommands: request.access == .commandApproval ? requested : []
            )
        }

        if request.access == .fullAccess {
            guard approvals.count < 8 else {
                return NectoShellApprovalResult(approved: false, access: .fullAccess)
            }
            return await enqueue(request, alreadyApproved: [])
        }

        let alreadyApproved = grant.level == .commandApproval
            ? requested.intersection(grant.approvedCommands)
            : []
        let outstanding = requested.subtracting(alreadyApproved)
        guard !outstanding.isEmpty else {
            return NectoShellApprovalResult(
                approved: true,
                access: .commandApproval,
                approvedCommands: requested
            )
        }
        guard approvals.count < 8 else {
            return NectoShellApprovalResult(
                approved: !alreadyApproved.isEmpty,
                access: .commandApproval,
                approvedCommands: alreadyApproved
            )
        }

        return await enqueue(
            NectoShellApprovalRequest(
                id: request.id,
                principal: request.principal,
                commands: outstanding.sorted(),
                access: .commandApproval,
                title: request.title,
                message: request.message
            ),
            alreadyApproved: alreadyApproved
        )
    }

    private func enqueue(
        _ request: NectoShellApprovalRequest,
        alreadyApproved: Set<String>
    ) async -> NectoShellApprovalResult {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvals.append(QueuedApproval(
                    id: id,
                    request: request,
                    alreadyApproved: alreadyApproved,
                    continuation: continuation
                ))
                presentNextApproval()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: id)
            }
        }
    }

    func cancelRequests(for principal: NectoPluginPrincipal) {
        let ids = approvals.compactMap {
            $0.request.principal == principal ? $0.id : nil
        }
        for id in ids {
            cancelRequest(id: id)
        }
    }

    func approvePendingRequest(id: UUID) {
        resolvePendingRequest(id: id, approved: true)
    }

    func denyPendingRequest(id: UUID) {
        resolvePendingRequest(id: id, approved: false)
    }

    private func resolvePendingRequest(id: UUID, approved: Bool) {
        guard pendingApproval?.id == id, let current = approvals.first, current.id == id else { return }
        approvals.removeFirst()
        pendingApproval = nil

        Task {
            let commands = approved ? Set(current.request.commands) : []
            do {
                if approved {
                    if current.request.access == .fullAccess {
                        persist(await policy.setAccessLevel(.fullAccess, for: current.request.principal))
                    } else {
                        var updated = snapshot
                        for command in commands {
                            updated = try await policy.approve(command, for: current.request.principal)
                        }
                        persist(updated)
                    }
                }
                current.continuation.resume(returning: NectoShellApprovalResult(
                    approved: approved,
                    access: current.request.access,
                    approvedCommands: current.alreadyApproved.union(commands)
                ))
            } catch {
                current.continuation.resume(returning: NectoShellApprovalResult(
                    approved: !current.alreadyApproved.isEmpty,
                    access: current.request.access,
                    approvedCommands: current.alreadyApproved
                ))
            }
            presentNextApproval()
        }
    }

    private func cancelRequest(id: UUID) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let cancelled = approvals.remove(at: index)
        if pendingApproval?.id == id {
            pendingApproval = nil
        }
        cancelled.continuation.resume(returning: NectoShellApprovalResult(
            approved: false,
            access: cancelled.request.access,
            approvedCommands: cancelled.alreadyApproved
        ))
        presentNextApproval()
    }

    private func presentNextApproval() {
        guard pendingApproval == nil, let next = approvals.first else { return }
        pendingApproval = PendingApproval(id: next.id, request: next.request)
    }

    private func persist(_ updated: NectoShellPolicySnapshot) {
        snapshot = updated
        saveSnapshot(updated)
    }
}
