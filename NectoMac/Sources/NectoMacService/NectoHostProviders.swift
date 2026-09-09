//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

public struct NectoHostInfoProvider: NectoOperationProvider {
    public static let key = "necto.desktop.info"

    public let descriptor = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: key, version: 1),
        kind: .once
    )

    private let nectoVersion: NectoSemanticVersion

    public init(nectoVersion: NectoSemanticVersion) {
        self.nectoVersion = nectoVersion
    }

    public func invoke(input _: NectoJSONValue, context _: NectoInvocationContext) async throws -> NectoJSONValue {
        [
            "nectoVersion": .string(nectoVersion.description),
            "protocolVersion": .number(Double(NectoProtocol.currentVersion)),
        ]
    }
}

/// Exercises the stream path until transport lands.
public struct NectoHostTicksProvider: NectoOperationProvider {
    public static let key = "necto.desktop.ticks"

    public let descriptor = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: key, version: 1),
        kind: .stream
    )

    public init() {}

    public func subscribe(
        input: NectoJSONValue,
        context _: NectoInvocationContext
    ) async throws -> AsyncThrowingStream<NectoJSONValue, any Error> {
        let interval = max(100, Int(input["intervalMs"]?.numberValue ?? 1000))

        return AsyncThrowingStream { continuation in
            let task = Task {
                var sequence = 0
                while !Task.isCancelled {
                    sequence += 1
                    continuation.yield([
                        "sequence": .number(Double(sequence)),
                        "timestamp": .number(Date().timeIntervalSince1970 * 1000),
                    ])
                    do {
                        try await Task.sleep(for: .milliseconds(interval))
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
