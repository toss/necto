//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel

/// Reads shell declarations without providers, execution or permission state.
public enum NectoShellOperationInterpreter {
    public enum Interpretation: Sendable, Equatable {
        case execute(NectoJSONSchema.StringValues)
        case authorizationRequest
        case unsupportedContract
    }

    public struct Operation: Sendable, Equatable {
        public let operationID: String
        public let description: String
        public let binding: NectoBridgeBinding
        public let kind: NectoOperationKind
        public let interpretation: Interpretation
    }

    public static func interpret(operations: [NectoOperation]) -> [Operation] {
        operations.compactMap { operation in
            let executionContracts = NectoShellContracts.executions.filter {
                $0.descriptor.name == operation.binding.name
            }
            let authorization = NectoShellContracts.authorization
            let interpretation: Interpretation
            if !executionContracts.isEmpty {
                if let contract = executionContracts.first(where: {
                    $0.descriptor.mismatch(with: operation) == nil
                }) {
                    interpretation = .execute(NectoJSONSchema.declaredStringValues(
                        for: contract.commandField,
                        in: operation.inputSchema
                    ))
                } else {
                    interpretation = .unsupportedContract
                }
            } else if authorization.name == operation.binding.name {
                interpretation = authorization.mismatch(with: operation) == nil
                    ? .authorizationRequest : .unsupportedContract
            } else {
                return nil
            }
            return Operation(
                operationID: operation.id,
                description: operation.description,
                binding: operation.binding,
                kind: operation.kind,
                interpretation: interpretation
            )
        }
    }
}
