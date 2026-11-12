//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel

public enum NectoShellContracts {
    public struct Execution: Sendable {
        public let descriptor: NectoBridgeDescriptor
        public let commandField: String
    }

    public static let execution = makeExecution(version: 1, standardInput: false)
    public static let executionWithStandardInput = makeExecution(version: 2, standardInput: true)
    public static let executions = [execution, executionWithStandardInput]

    public static let authorization = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: "necto.desktop.shell.authorization.request", version: 1),
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

    private static func makeExecution(version: Int, standardInput: Bool) -> Execution {
        let commandField = "command"
        var inputProperties: [String: NectoJSONValue] = [commandField: ["type": "string"]]
        if standardInput {
            inputProperties["stdin"] = [
                "type": "string",
                "maxLength": .number(Double(NectoBashExecutor.maximumStandardInputBytes)),
            ]
        }

        let descriptor = NectoBridgeDescriptor(
            binding: NectoBridgeBinding(name: "necto.desktop.shell.execute", version: version),
            kind: .once,
            inputSchema: [
                "type": "object",
                "properties": .object(inputProperties),
                "required": [.string(commandField)],
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
        return Execution(descriptor: descriptor, commandField: commandField)
    }
}
