//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoCLIService
import NectoModel
import Foundation

public enum NectoShellIdentity {
    public static let cli = NectoPluginPrincipal(
        pluginID: NectoCLIShell.pluginID,
        sourceIdentity: NectoCLIShell.sourceIdentity
    )
}

public enum NectoShellAccessLevel: String, Sendable, Codable, CaseIterable {
    case protected
    case commandApproval
    case fullAccess
}

public struct NectoShellGrant: Sendable, Codable, Equatable {
    public let principal: NectoPluginPrincipal
    public var level: NectoShellAccessLevel
    public var approvedCommands: Set<String>
    public var contentIdentity: String?

    public init(
        principal: NectoPluginPrincipal,
        level: NectoShellAccessLevel = .protected,
        approvedCommands: Set<String> = [],
        contentIdentity: String? = nil
    ) {
        self.principal = principal
        self.level = level
        self.approvedCommands = approvedCommands
        self.contentIdentity = contentIdentity
    }
}

public struct NectoShellPolicySnapshot: Sendable, Codable, Equatable {
    public var isFullAccessEnabled: Bool
    public var grants: [NectoShellGrant]

    public init(isFullAccessEnabled: Bool = false, grants: [NectoShellGrant] = []) {
        self.isFullAccessEnabled = isFullAccessEnabled
        self.grants = grants
    }
}

/// The single decision point for every shell caller.
///
/// The manifest grants access to the bridge. This policy grants access to one command.
/// Keeping the two decisions separate prevents an install-time bridge approval from
/// silently becoming approval for every command a plugin can construct later.
public actor NectoShellPolicy {
    /// Combines interpreted declarations with current policy without granting access.
    public struct Review: Sendable, Equatable {
        public let requestedOperations: [NectoShellOperationInterpreter.Operation]
        public let currentGrant: NectoShellGrant?
        public let isFullAccessEnabled: Bool
        fileprivate let approvableDeclaredCommands: Set<String>?

        public var requestsShellAccess: Bool { !requestedOperations.isEmpty }

        public var canApproveDeclaredCommands: Bool { approvableDeclaredCommands != nil }

        public var requiresAccessChoice: Bool { requestsShellAccess && !isFullAccessEnabled }

        public var availableAccessLevels: [NectoShellAccessLevel] {
            guard requiresAccessChoice else { return [] }
            return canApproveDeclaredCommands
                ? [.fullAccess, .commandApproval, .protected]
                : [.fullAccess, .protected]
        }

        public var effectiveAccessLevel: NectoShellAccessLevel {
            isFullAccessEnabled ? .fullAccess : currentGrant?.level ?? .protected
        }

        public func validateInstallationChoice(_ level: NectoShellAccessLevel?) throws {
            if let level {
                guard availableAccessLevels.contains(level) else { throw InstallationError.unavailableAccessLevel }
            } else if requiresAccessChoice {
                throw InstallationError.unavailableAccessLevel
            }
        }
    }

    public struct InstallationChange: Sendable {
        fileprivate let previousGrant: NectoShellGrant?
        fileprivate let grant: NectoShellGrant
        public let snapshot: NectoShellPolicySnapshot
    }

    public enum InstallationError: LocalizedError, Sendable {
        case staleReview
        case unavailableAccessLevel

        public var errorDescription: String? {
            switch self {
            case .staleReview: "Shell access changed while the plugin was under review. Review the installation again."
            case .unavailableAccessLevel: "Choose an available shell access level before installing."
            }
        }
    }

    private var isFullAccessEnabled: Bool
    private var grants: [NectoPluginPrincipal: NectoShellGrant]

    public init(snapshot: NectoShellPolicySnapshot = NectoShellPolicySnapshot()) {
        isFullAccessEnabled = snapshot.isFullAccessEnabled
        grants = Dictionary(
            snapshot.grants.map { ($0.principal, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public func snapshot() -> NectoShellPolicySnapshot {
        NectoShellPolicySnapshot(
            isFullAccessEnabled: isFullAccessEnabled,
            grants: grants.values.sorted {
                ($0.principal.pluginID, $0.principal.sourceIdentity)
                    < ($1.principal.pluginID, $1.principal.sourceIdentity)
            }
        )
    }

    public func access(for principal: NectoPluginPrincipal) -> NectoShellGrant {
        grants[principal] ?? NectoShellGrant(principal: principal)
    }

    /// The caller interprets the staged declarations first. Pass the verified
    /// existing installation principal for updates; new candidates have no grant.
    public func review(
        interpretedOperations: [NectoShellOperationInterpreter.Operation],
        for principal: NectoPluginPrincipal? = nil
    ) -> Review {
        Review(
            requestedOperations: interpretedOperations,
            currentGrant: principal.flatMap { grants[$0] },
            isFullAccessEnabled: isFullAccessEnabled,
            approvableDeclaredCommands: Self.approvableDeclaredCommands(in: interpretedOperations)
        )
    }

    public func applyInstallationChoice(
        review: Review,
        level: NectoShellAccessLevel?,
        for principal: NectoPluginPrincipal
    ) throws -> InstallationChange? {
        let previousGrant = grants[principal]
        guard isFullAccessEnabled == review.isFullAccessEnabled, previousGrant == review.currentGrant else {
            throw InstallationError.staleReview
        }
        try review.validateInstallationChoice(level)
        guard let level else { return nil }

        var grant = previousGrant ?? NectoShellGrant(principal: principal)
        grant.level = level
        grant.approvedCommands = level == .commandApproval ? review.approvableDeclaredCommands ?? [] : []
        guard grant != previousGrant else { return nil }
        grants[principal] = grant
        return InstallationChange(previousGrant: previousGrant, grant: grant, snapshot: snapshot())
    }

    /// Restores only the grant written by the failed installation if it still matches.
    public func rollbackInstallationChoice(_ change: InstallationChange) -> NectoShellPolicySnapshot? {
        let principal = change.grant.principal
        guard grants[principal] == change.grant else { return nil }
        grants[principal] = change.previousGrant
        return snapshot()
    }

    private static func approvableDeclaredCommands(
        in operations: [NectoShellOperationInterpreter.Operation]
    ) -> Set<String>? {
        var declaredCommands: Set<String> = []
        for operation in operations {
            switch operation.interpretation {
            case let .execute(.values(commands)):
                guard !operation.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !commands.isEmpty,
                      commands.allSatisfy({ (try? validated($0)) != nil }) else { return nil }
                declaredCommands.formUnion(commands)
            case .execute(.unavailable), .unsupportedContract:
                return nil
            case .authorizationRequest:
                continue
            }
        }
        return declaredCommands.isEmpty ? nil : declaredCommands
    }

    public func allows(_ command: String, for principal: NectoPluginPrincipal) -> Bool {
        if isFullAccessEnabled { return true }

        let grant = access(for: principal)
        switch grant.level {
        case .protected:
            return false
        case .commandApproval:
            return grant.approvedCommands.contains(command)
        case .fullAccess:
            return true
        }
    }

    @discardableResult
    public func setFullAccessEnabled(_ enabled: Bool) -> NectoShellPolicySnapshot {
        isFullAccessEnabled = enabled
        return snapshot()
    }

    @discardableResult
    public func setAccessLevel(
        _ level: NectoShellAccessLevel,
        for principal: NectoPluginPrincipal
    ) -> NectoShellPolicySnapshot {
        var grant = access(for: principal)
        grant.level = level
        grants[principal] = grant
        return snapshot()
    }

    /// Records the latest trusted content, not authorization identity. The host must
    /// approve local updates before registering them; device content is trusted by app.
    @discardableResult
    public func registerContentIdentity(
        _ contentIdentity: String,
        for principal: NectoPluginPrincipal
    ) -> NectoShellPolicySnapshot {
        var grant = access(for: principal)
        grant.contentIdentity = contentIdentity
        grants[principal] = grant
        return snapshot()
    }

    @discardableResult
    public func approve(
        _ command: String,
        for principal: NectoPluginPrincipal
    ) throws -> NectoShellPolicySnapshot {
        let command = try Self.validated(command)
        var grant = access(for: principal)
        grant.level = .commandApproval
        grant.approvedCommands.insert(command)
        grants[principal] = grant
        return snapshot()
    }

    @discardableResult
    public func revoke(
        _ command: String,
        for principal: NectoPluginPrincipal
    ) -> NectoShellPolicySnapshot {
        var grant = access(for: principal)
        grant.approvedCommands.remove(command)
        grants[principal] = grant
        return snapshot()
    }

    @discardableResult
    public func revokeAll(for principal: NectoPluginPrincipal) -> NectoShellPolicySnapshot {
        var grant = access(for: principal)
        grant.approvedCommands.removeAll()
        grants[principal] = grant
        return snapshot()
    }

    @discardableResult
    public func forget(_ principal: NectoPluginPrincipal) -> NectoShellPolicySnapshot {
        grants.removeValue(forKey: principal)
        return snapshot()
    }

    public static func validated(_ command: String) throws -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NectoBridgeError(code: .invalidInput, message: "command must not be empty")
        }
        guard !command.contains("\0") else {
            throw NectoBridgeError(code: .invalidInput, message: "command must not contain NUL")
        }
        return command
    }
}
