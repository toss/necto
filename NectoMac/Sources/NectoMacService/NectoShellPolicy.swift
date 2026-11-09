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
        public let canApproveDeclaredCommands: Bool
        public let currentGrant: NectoShellGrant?
        public let isFullAccessEnabled: Bool

        public var requestsShellAccess: Bool { !requestedOperations.isEmpty }

        public var effectiveAccessLevel: NectoShellAccessLevel {
            isFullAccessEnabled ? .fullAccess : currentGrant?.level ?? .protected
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
            canApproveDeclaredCommands: Self.canApproveDeclaredCommands(in: interpretedOperations),
            currentGrant: principal.flatMap { grants[$0] },
            isFullAccessEnabled: isFullAccessEnabled
        )
    }

    private static func canApproveDeclaredCommands(
        in operations: [NectoShellOperationInterpreter.Operation]
    ) -> Bool {
        var hasExecution = false
        for operation in operations {
            switch operation.interpretation {
            case let .execute(.values(commands)):
                guard !operation.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !commands.isEmpty,
                      commands.allSatisfy({ (try? validated($0)) != nil }) else { return false }
                hasExecution = true
            case .execute(.unavailable), .unsupportedContract:
                return false
            case .authorizationRequest:
                continue
            }
        }
        return hasExecution
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
