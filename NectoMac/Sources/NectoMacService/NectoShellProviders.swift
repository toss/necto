//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

public struct NectoShellExecutionResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol NectoShellExecuting: Sendable {
    func execute(_ command: String) async throws -> NectoShellExecutionResult
    func execute(_ command: String, standardInput: Data?) async throws -> NectoShellExecutionResult
}

public extension NectoShellExecuting {
    func execute(_ command: String, standardInput: Data?) async throws -> NectoShellExecutionResult {
        guard standardInput == nil else {
            throw NectoBridgeError(code: .operationUnavailable, message: "This executor does not support standard input.")
        }
        return try await execute(command)
    }
}

/// Executes the exact script the policy approved, in a predictable Bash environment.
public struct NectoBashExecutor: NectoShellExecuting {
    public struct Limits: Sendable {
        public let timeoutMilliseconds: Int
        public let outputBytes: Int

        public init(timeoutMilliseconds: Int = 30_000, outputBytes: Int = 1_048_576) {
            self.timeoutMilliseconds = timeoutMilliseconds
            self.outputBytes = outputBytes
        }
    }

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    // Preload at most one atomic pipe write before launch, avoiding a blocked writer
    // or SIGPIPE if a command exits without consuming input.
    public static let maximumStandardInputBytes = NectoProcessRunner.maximumStandardInputBytes

    public func execute(_ command: String) async throws -> NectoShellExecutionResult {
        try await execute(command, standardInput: nil)
    }

    public func execute(_ command: String, standardInput: Data?) async throws -> NectoShellExecutionResult {
        guard (standardInput?.count ?? 0) <= Self.maximumStandardInputBytes else {
            throw NectoBridgeError(code: .invalidInput, message: "Standard input exceeds the supported byte limit.")
        }
        let command = try NectoShellPolicy.validated(command)
        var environment = ProcessInfo.processInfo.environment
        for key in ["BASH_ENV", "ENV", "CDPATH"] { environment.removeValue(forKey: key) }
        for key in environment.keys.filter({ $0.hasPrefix("DYLD_") }) {
            environment.removeValue(forKey: key)
        }
        do {
            let output = try await NectoProcessRunner.run(
                "/bin/bash", arguments: ["--noprofile", "--norc", "-c", command],
                environment: environment, directory: FileManager.default.homeDirectoryForCurrentUser,
                standardInput: standardInput,
                timeoutMilliseconds: limits.timeoutMilliseconds, maximumOutputBytes: limits.outputBytes
            )
            return NectoShellExecutionResult(
                stdout: String(decoding: output.stdout, as: UTF8.self),
                stderr: String(decoding: output.stderr, as: UTF8.self), exitCode: output.exitCode
            )
        } catch NectoProcessRunner.Failure.timedOut {
            throw NectoBridgeError(code: .timeout, message: "Shell command exceeded \(limits.timeoutMilliseconds)ms")
        } catch NectoProcessRunner.Failure.outputLimitExceeded {
            throw NectoBridgeError(code: .providerFailed, message: "Shell output exceeded \(limits.outputBytes) bytes")
        }
    }
}

actor NectoShellExecutionLimiter {
    private let maximumTotal: Int
    private let maximumPerPrincipal: Int
    private var total = 0
    private var counts: [NectoPluginPrincipal: Int] = [:]

    init(maximumTotal: Int = 4, maximumPerPrincipal: Int = 2) {
        self.maximumTotal = maximumTotal
        self.maximumPerPrincipal = maximumPerPrincipal
    }

    func acquire(for principal: NectoPluginPrincipal) throws {
        guard total < maximumTotal, counts[principal, default: 0] < maximumPerPrincipal else {
            throw NectoBridgeError(
                code: .operationUnavailable,
                message: "Too many shell commands are already running"
            )
        }
        total += 1
        counts[principal, default: 0] += 1
    }

    func release(for principal: NectoPluginPrincipal) {
        total = max(0, total - 1)
        let remaining = max(0, counts[principal, default: 0] - 1)
        if remaining == 0 {
            counts.removeValue(forKey: principal)
        } else {
            counts[principal] = remaining
        }
    }
}

public enum NectoShellApprovalAccess: String, Sendable, Equatable {
    case commandApproval
    case fullAccess
}

public struct NectoShellApprovalResult: Sendable, Equatable {
    public let approved: Bool
    public let access: NectoShellApprovalAccess
    public let approvedCommands: Set<String>

    public init(
        approved: Bool,
        access: NectoShellApprovalAccess,
        approvedCommands: Set<String> = []
    ) {
        self.approved = approved
        self.access = access
        self.approvedCommands = approvedCommands
    }
}

public struct NectoShellApprovalRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let principal: NectoPluginPrincipal
    public let commands: [String]
    public let access: NectoShellApprovalAccess
    public let title: String?
    public let message: String?

    public init(
        id: String = UUID().uuidString,
        principal: NectoPluginPrincipal,
        commands: [String],
        access: NectoShellApprovalAccess = .commandApproval,
        title: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.principal = principal
        self.commands = commands
        self.access = access
        self.title = title
        self.message = message
    }
}

public protocol NectoShellApprovalRequesting: Sendable {
    /// Returns what the person approved. The requester owns persistence.
    func requestApproval(_ request: NectoShellApprovalRequest) async -> NectoShellApprovalResult
}

public struct NectoShellExecuteProvider: NectoOperationProvider {
    public static let key = "necto.desktop.shell.execute"

    public let descriptor: NectoBridgeDescriptor

    private let policy: NectoShellPolicy
    private let executor: any NectoShellExecuting
    private let limiter: NectoShellExecutionLimiter

    public init(policy: NectoShellPolicy, executor: any NectoShellExecuting = NectoBashExecutor()) {
        self.init(policy: policy, executor: executor, limiter: NectoShellExecutionLimiter())
    }

    init(
        policy: NectoShellPolicy,
        executor: any NectoShellExecuting,
        limiter: NectoShellExecutionLimiter,
        standardInput: Bool = false
    ) {
        self.policy = policy
        self.executor = executor
        self.limiter = limiter
        self.descriptor = NectoBridgeDescriptor(
            binding: NectoBridgeBinding(name: Self.key, version: standardInput ? 2 : 1),
            kind: .once,
            inputSchema: [
                "type": "object",
                "properties": standardInput
                    ? ["command": ["type": "string"], "stdin": ["type": "string", "maxLength": .number(Double(NectoBashExecutor.maximumStandardInputBytes))]]
                    : ["command": ["type": "string"]],
                "required": ["command"],
                "additionalProperties": false,
            ],
            outputSchema: [
                "type": "object",
                "properties": [
                    "stdout": ["type": "string"],
                    "stderr": ["type": "string"],
                    "exitCode": ["type": "integer"],
                ],
                "required": ["stdout", "stderr", "exitCode"],
                "additionalProperties": false,
            ]
        )
    }

    public func supportingStandardInput() -> NectoShellExecuteProvider {
        NectoShellExecuteProvider(policy: policy, executor: executor, limiter: limiter, standardInput: true)
    }

    public func invoke(
        input: NectoJSONValue,
        context: NectoInvocationContext
    ) async throws -> NectoJSONValue {
        guard let raw = input["command"]?.stringValue else {
            throw NectoBridgeError(code: .invalidInput, message: "command is required")
        }
        let command = try NectoShellPolicy.validated(raw)
        guard await policy.allows(command, for: context.principal) else {
            throw NectoBridgeError(
                code: .permissionDenied,
                message: "The command has not been approved for this plugin",
                details: ["command": .string(command)]
            )
        }

        var standardInput: Data?
        if let inputValue = input["stdin"] {
            guard descriptor.binding.version == 2, let text = inputValue.stringValue,
                  text.utf8.count <= NectoBashExecutor.maximumStandardInputBytes else {
                throw NectoBridgeError(code: .invalidInput, message: "stdin requires shell.execute v2 and must fit the supported byte limit.")
            }
            standardInput = Data(text.utf8)
        }
        try await limiter.acquire(for: context.principal)
        let result: NectoShellExecutionResult
        do {
            result = try await executor.execute(command, standardInput: standardInput)
        } catch {
            await limiter.release(for: context.principal)
            throw error
        }
        await limiter.release(for: context.principal)
        return [
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "exitCode": .number(Double(result.exitCode)),
        ]
    }
}

public struct NectoShellAuthorizationProvider: NectoOperationProvider {
    public static let key = "necto.desktop.shell.authorization.request"

    public let descriptor = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: key, version: 1),
        kind: .once,
        inputSchema: [
            "type": "object",
            "properties": [
                "commands": ["type": "array", "items": ["type": "string"]],
                "access": ["type": "string", "enum": ["commandApproval", "fullAccess"]],
                "title": ["type": "string", "maxLength": 80],
                "message": ["type": "string", "maxLength": 500],
                "reason": ["type": "string", "maxLength": 500],
            ],
            "additionalProperties": false,
        ],
        outputSchema: [
            "type": "object",
            "properties": [
                "approved": ["type": "boolean"],
                "approvedCommands": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["approved", "approvedCommands"],
            "additionalProperties": false,
        ]
    )

    private let requester: any NectoShellApprovalRequesting

    public init(requester: any NectoShellApprovalRequesting) {
        self.requester = requester
    }

    public func invoke(
        input: NectoJSONValue,
        context: NectoInvocationContext
    ) async throws -> NectoJSONValue {
        let access = NectoShellApprovalAccess(
            rawValue: input["access"]?.stringValue ?? NectoShellApprovalAccess.commandApproval.rawValue
        ) ?? .commandApproval
        let rawCommands = input["commands"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if access == .commandApproval, rawCommands.isEmpty {
            throw NectoBridgeError(code: .invalidInput, message: "commands must not be empty for Command approval")
        }
        if access == .fullAccess, !rawCommands.isEmpty {
            throw NectoBridgeError(code: .invalidInput, message: "Full access requests must not include commands")
        }
        let commands = try rawCommands.map(NectoShellPolicy.validated)
        let result = await requester.requestApproval(NectoShellApprovalRequest(
            id: context.requestID,
            principal: context.principal,
            commands: Array(Set(commands)).sorted(),
            access: access,
            title: input["title"]?.stringValue,
            message: input["message"]?.stringValue ?? input["reason"]?.stringValue
        ))

        return [
            "approved": .bool(result.approved),
            "approvedCommands": .array(result.approvedCommands.sorted().map(NectoJSONValue.string)),
        ]
    }
}
