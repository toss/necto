//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoMacService

private let shellPrincipal = NectoPluginPrincipal(pluginID: "target-notes", sourceIdentity: "/plugins/target-notes")
private let shellContext = NectoInvocationContext(principal: shellPrincipal, target: nil)

private actor RecordingExecutor: NectoShellExecuting {
    private(set) var commands: [String] = []

    func execute(_ command: String) async throws -> NectoShellExecutionResult {
        commands.append(command)
        return NectoShellExecutionResult(stdout: "ok\n", stderr: "", exitCode: 0)
    }
}

private actor ApprovalRequester: NectoShellApprovalRequesting {
    let approved: Set<String>
    let access: NectoShellApprovalAccess
    private(set) var request: NectoShellApprovalRequest?

    init(approved: Set<String>, access: NectoShellApprovalAccess = .commandApproval) {
        self.approved = approved
        self.access = access
    }

    func requestApproval(_ request: NectoShellApprovalRequest) async -> NectoShellApprovalResult {
        self.request = request
        return NectoShellApprovalResult(
            approved: true,
            access: access,
            approvedCommands: approved
        )
    }
}

@Suite("Shell providers")
struct NectoShellProviderTests {
    @Test("standard input reaches Bash without becoming part of its approved command")
    func passesStandardInputSeparately() async throws {
        let policy = NectoShellPolicy()
        try await policy.approve("/bin/cat", for: shellPrincipal)
        let provider = NectoShellExecuteProvider(policy: policy).supportingStandardInput()
        let output = try await provider.invoke(input: ["command": "/bin/cat", "stdin": "fixture-input"], context: shellContext)
        #expect(output["stdout"] == "fixture-input")
        #expect(await policy.access(for: shellPrincipal).approvedCommands == ["/bin/cat"])
    }

    @Test("oversized standard input is refused before execution")
    func boundsStandardInput() async throws {
        let policy = NectoShellPolicy()
        try await policy.approve("true", for: shellPrincipal)
        let provider = NectoShellExecuteProvider(policy: policy).supportingStandardInput()
        let error = await #expect(throws: NectoBridgeError.self) {
            try await provider.invoke(input: ["command": "true", "stdin": .string(String(repeating: "x", count: 513))], context: shellContext)
        }
        #expect(error?.code == .invalidInput)
    }

    @Test("a command may exit without reading its standard input")
    func exitsWithoutReadingStandardInput() async throws {
        let policy = NectoShellPolicy()
        try await policy.approve("exit 0", for: shellPrincipal)
        let provider = NectoShellExecuteProvider(policy: policy).supportingStandardInput()
        let output = try await provider.invoke(input: ["command": "exit 0", "stdin": "fixture-input"], context: shellContext)
        #expect(output["exitCode"] == 0)
    }

    @Test("refuses an unapproved command before execution")
    func refusesBeforeExecution() async {
        let policy = NectoShellPolicy()
        let executor = RecordingExecutor()
        let provider = NectoShellExecuteProvider(policy: policy, executor: executor)

        let error = await #expect(throws: NectoBridgeError.self) {
            try await provider.invoke(input: ["command": "git status"], context: shellContext)
        }

        #expect(error?.code == .permissionDenied)
        #expect(await executor.commands.isEmpty)
    }

    @Test("executes an exact approved command and returns structured output")
    func executesApproved() async throws {
        let policy = NectoShellPolicy()
        try await policy.approve("git status --short", for: shellPrincipal)
        let executor = RecordingExecutor()
        let provider = NectoShellExecuteProvider(policy: policy, executor: executor)

        let output = try await provider.invoke(
            input: ["command": "git status --short"],
            context: shellContext
        )

        #expect(output["stdout"] == "ok\n")
        #expect(output["stderr"] == "")
        #expect(output["exitCode"] == 0)
        #expect(await executor.commands == ["git status --short"])
    }

    @Test("authorization requests are scoped to the calling principal")
    func requestsAuthorization() async throws {
        let requester = ApprovalRequester(approved: ["git status"])
        let provider = NectoShellAuthorizationProvider(requester: requester)

        let output = try await provider.invoke(
            input: [
                "commands": ["git status"],
                "title": "Inspect repository state",
                "message": "Read the current branch before continuing",
            ],
            context: shellContext
        )

        #expect(output["approved"] == true)
        #expect(output["approvedCommands"] == ["git status"])
        #expect(await requester.request?.principal == shellPrincipal)
        #expect(await requester.request?.id == shellContext.requestID)
        #expect(await requester.request?.title == "Inspect repository state")
        #expect(await requester.request?.message == "Read the current branch before continuing")
    }

    @Test("legacy reason is accepted as the request message")
    func acceptsLegacyReason() async throws {
        let requester = ApprovalRequester(approved: ["git status"])
        let provider = NectoShellAuthorizationProvider(requester: requester)

        _ = try await provider.invoke(
            input: ["commands": ["git status"], "reason": "Legacy explanation"],
            context: shellContext
        )

        #expect(await requester.request?.message == "Legacy explanation")
    }

    @Test("a plugin can request full access without listing commands")
    func requestsFullAccess() async throws {
        let requester = ApprovalRequester(approved: [], access: .fullAccess)
        let provider = NectoShellAuthorizationProvider(requester: requester)

        let output = try await provider.invoke(
            input: [
                "access": "fullAccess",
                "title": "Allow all Shell Demo commands?",
                "message": "This is intentionally broad.",
            ],
            context: shellContext
        )

        #expect(output["approved"] == true)
        #expect(output["approvedCommands"] == [])
        #expect(await requester.request?.access == .fullAccess)
        #expect(await requester.request?.commands.isEmpty == true)
    }

    @Test("stops a command at the provider deadline")
    func enforcesTimeout() async {
        let executor = NectoBashExecutor(limits: .init(timeoutMilliseconds: 100, outputBytes: 1_024))

        let error = await #expect(throws: NectoBridgeError.self) {
            try await executor.execute("sleep 5")
        }

        #expect(error?.code == .timeout)
    }

    @Test("runs from the user home directory")
    func usesHomeDirectory() async throws {
        let result = try await NectoBashExecutor().execute("pwd")

        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test("stops a command before its output grows without bound")
    func enforcesOutputLimit() async {
        let executor = NectoBashExecutor(limits: .init(timeoutMilliseconds: 2_000, outputBytes: 128))

        let error = await #expect(throws: NectoBridgeError.self) {
            try await executor.execute("for ((i=0; i<2048; i++)); do printf x; done")
        }

        #expect(error?.code == .providerFailed)
    }

    @Test("cancellation terminates the launched shell process")
    func cancellationTerminates() async {
        let executor = NectoBashExecutor(limits: .init(timeoutMilliseconds: 5_000, outputBytes: 1_024))
        let task = Task {
            try await executor.execute("sleep 5")
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("limits concurrent commands globally and per principal")
    func limitsConcurrency() async throws {
        let limiter = NectoShellExecutionLimiter(maximumTotal: 2, maximumPerPrincipal: 1)
        let another = NectoPluginPrincipal(pluginID: "other", sourceIdentity: "/plugins/other")

        try await limiter.acquire(for: shellPrincipal)
        let principalError = await #expect(throws: NectoBridgeError.self) {
            try await limiter.acquire(for: shellPrincipal)
        }
        #expect(principalError?.code == .operationUnavailable)

        try await limiter.acquire(for: another)
        let totalError = await #expect(throws: NectoBridgeError.self) {
            try await limiter.acquire(for: NectoPluginPrincipal(pluginID: "third", sourceIdentity: "/plugins/third"))
        }
        #expect(totalError?.code == .operationUnavailable)

        await limiter.release(for: shellPrincipal)
        await limiter.release(for: another)
    }
}
