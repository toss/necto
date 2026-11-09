//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing

@testable import NectoMacService

@Suite("Shell operation interpreter")
struct NectoShellOperationInterpreterTests {
    @Test("decoded shell declarations retain metadata and exact command candidates in manifest order")
    func interpretsDecodedDeclarations() throws {
        let v2 = operation(
            id: "shell.run-v2", version: 2, description: " Read Git diagnostics ",
            properties: [
                "command": ["type": "string", "enum": [" git status ", "git log"]],
                "stdin": ["type": "string", "enum": ["sample input"]],
            ]
        )
        let authorization = operation(
            id: "shell.request", binding: "necto.desktop.shell.authorization.request",
            properties: ["commands": ["type": "array", "items": ["type": "string"]]]
        )
        let unrelated = operation(id: "records.list", binding: "necto.desktop.network-records.list")
        let v1 = operation(id: "shell.run-v1", description: "Read the current directory")
        let shellOperations = [v2, authorization, v1]
        let encoded = try JSONEncoder().encode(manifest(operations: [v2, authorization, unrelated, v1]))
        let decoded = try JSONDecoder().decode(NectoPluginManifest.self, from: encoded)

        let interpreted = NectoShellOperationInterpreter.interpret(operations: decoded.operations)

        #expect(interpreted.map(\.operationID) == shellOperations.map(\.id))
        #expect(interpreted.map(\.description) == shellOperations.map(\.description))
        #expect(interpreted.map(\.binding) == shellOperations.map(\.binding))
        #expect(interpreted.map(\.kind) == shellOperations.map(\.kind))
        #expect(interpreted.map(\.interpretation) == [
            .execute(.values([" git status ", "git log"])),
            .authorizationRequest,
            .execute(.values(["pwd"])),
        ])
    }

    @Test("recognized shell names retain unknown versions and incorrect kinds")
    func preservesUnsupportedContracts() {
        let operations = [
            operation(id: "shell.future", version: 3),
            operation(id: "shell.stream", kind: .stream),
            operation(id: "shell.request-future", binding: "necto.desktop.shell.authorization.request", version: 2),
            operation(id: "shell.request-stream", binding: "necto.desktop.shell.authorization.request", kind: .stream),
        ]
        let unrelated = operation(id: "device.shell", binding: "necto.device.shell.execute")
        let interpreted = NectoShellOperationInterpreter.interpret(operations: operations + [unrelated])

        #expect(interpreted.map(\.operationID) == operations.map(\.id))
        #expect(interpreted.map(\.description) == operations.map(\.description))
        #expect(interpreted.map(\.binding) == operations.map(\.binding))
        #expect(interpreted.map(\.kind) == operations.map(\.kind))
        #expect(interpreted.allSatisfy { $0.interpretation == .unsupportedContract })
    }

    @Test("missing or malformed command enums retain their operation and explain why values are unavailable")
    func reportsUnavailableCommandEnums() {
        let operations = [
            operation(id: "shell.missing-field", properties: [:]),
            operation(id: "shell.missing-enum", properties: ["command": ["type": "string"]]),
            operation(id: "shell.mixed-enum", properties: ["command": ["type": "string", "enum": ["pwd", 1]]]),
        ]
        let interpreted = NectoShellOperationInterpreter.interpret(operations: operations)

        #expect(interpreted.map(\.operationID) == operations.map(\.id))
        #expect(interpreted.map(\.interpretation) == [
            .execute(.unavailable(.propertyNotDeclared)),
            .execute(.unavailable(.enumNotDeclared)),
            .execute(.unavailable(.notStringEnum)),
        ])
    }

    @Test("blank and NUL-containing strings remain available to policy as declared candidates")
    func preservesCommandsForPolicyReview() {
        let commands = ["pwd", " \n\t", "git\0status", "pwd"]
        let operation = operation(
            id: "shell.candidates",
            properties: ["command": ["type": "string", "enum": .array(commands.map(NectoJSONValue.string))]]
        )
        let interpreted = NectoShellOperationInterpreter.interpret(operations: [operation])

        #expect(interpreted.map(\.interpretation) == [.execute(.values(commands))])
    }

    @Test("interpreter contract support agrees with registry availability for real shell providers",
          arguments: [NectoOperationKind.once, .stream])
    func agreesWithRegisteredProviders(kind: NectoOperationKind) async throws {
        let registry = NectoPluginRegistry()
        let execute = NectoShellExecuteProvider(policy: NectoShellPolicy())
        await registry.registerHostProvider(execute)
        await registry.registerHostProvider(execute.supportingStandardInput())
        await registry.registerHostProvider(NectoShellAuthorizationProvider(requester: DenyingApprovalRequester()))
        let operations = [
            operation(id: "shell.run-v1", kind: kind),
            operation(id: "shell.run-v2", version: 2, kind: kind),
            operation(id: "shell.run-v3", version: 3, kind: kind),
            operation(id: "shell.request-v1", binding: "necto.desktop.shell.authorization.request", kind: kind),
            operation(id: "shell.request-v2", binding: "necto.desktop.shell.authorization.request", version: 2, kind: kind),
        ]
        let manifest = manifest(operations: operations)
        try await registry.install(manifest: manifest, sourceIdentity: "local:fixture")

        let context = try #require(await registry.context(pluginID: manifest.id, target: nil))
        let interpreted = NectoShellOperationInterpreter.interpret(operations: operations)
        let supportsKind = kind == .once
        let expectedAvailability = [supportsKind, supportsKind, false, supportsKind, false]

        #expect(context.operations.map(\.id) == operations.map(\.id))
        #expect(context.operations.map(\.available) == expectedAvailability)
        #expect(context.operations.map { $0.unavailableReason == nil } == expectedAvailability)
        #expect(interpreted.map(\.operationID) == context.operations.map(\.id))
        #expect(interpreted.map { $0.interpretation != .unsupportedContract } == expectedAvailability)
    }

    private func manifest(operations: [NectoOperation]) -> NectoPluginManifest {
        NectoPluginManifest(
            type: .eventExporter, id: "shell-fixture", name: "Shell fixture", description: "Read diagnostics",
            version: "1.0.0", author: "Necto", icon: .init(systemName: "terminal"),
            assets: ["index.html"], allowedOrigins: ["self"], operations: operations
        )
    }

    private func operation(
        id: String,
        binding: String = "necto.desktop.shell.execute",
        version: Int = 1,
        kind: NectoOperationKind = .once,
        description: String = "Read local diagnostics",
        properties: NectoJSONValue = ["command": ["type": "string", "enum": ["pwd"]]]
    ) -> NectoOperation {
        NectoOperation(
            id: id,
            title: "Read diagnostics",
            description: description,
            kind: kind,
            binding: .init(name: binding, version: version),
            inputSchema: ["type": "object", "properties": properties],
            outputSchema: ["type": "object"],
            timeoutMs: 5_000
        )
    }
}

private struct DenyingApprovalRequester: NectoShellApprovalRequesting {
    func requestApproval(_ request: NectoShellApprovalRequest) async -> NectoShellApprovalResult {
        NectoShellApprovalResult(approved: false, access: request.access)
    }
}
