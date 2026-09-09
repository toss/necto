//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// How an operation answers, which is the only thing the runtime needs to know.
///
/// There is no read-or-write axis here. It would be declared by whoever wrote the
/// plugin and read on the install screen, which is the one place their word is worth
/// least — and the name already says it: `events.clear` is not mistaken for a read.
public enum NectoOperationKind: String, Sendable, Codable, CaseIterable {
    /// Answers once, through `send`.
    case once
    /// Keeps answering until it ends, through `subscribe`.
    case stream
}

/// An operation declared in the manifest. No field is optional.
///
/// The plugin's JavaScript calls `id`. It never names the bridge behind it, which is
/// what lets a plugin use readable names of its own while the runtime still resolves
/// to an exact, versioned contract.
public struct NectoOperation: Sendable, Hashable, Codable {
    public let id: String
    public let title: String
    public let description: String
    public let kind: NectoOperationKind
    public let binding: NectoBridgeBinding
    public let inputSchema: NectoJSONValue
    public let outputSchema: NectoJSONValue
    /// `0` means no limit. Streams normally use `0`.
    public let timeoutMs: Int

    public init(
        id: String,
        title: String,
        description: String,
        kind: NectoOperationKind,
        binding: NectoBridgeBinding,
        inputSchema: NectoJSONValue,
        outputSchema: NectoJSONValue,
        timeoutMs: Int
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.kind = kind
        self.binding = binding
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.timeoutMs = timeoutMs
    }
}
