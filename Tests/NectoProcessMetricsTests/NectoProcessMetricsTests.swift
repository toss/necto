//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoProcessMetrics
import Foundation
import Testing

@testable import NectoSDK

private func answer(
    _ plugin: any NectoPluginable,
    _ key: String,
    _ input: NectoJSONValue = [:]
) async throws -> NectoJSONValue {
    let collector = NectoHandler()
    plugin.register(collector)
    guard case let .once(body)? = collector.registrations["\(key)@1"]?.body else {
        throw NectoBridgeError(code: .operationUnavailable, message: key)
    }
    return try await body(input)
}

@Suite("Process performance plugin")
struct NectoProcessMetricsTests {
    @Test("offers six useful process series")
    func offersSixMetrics() async throws {
        let output = try await answer(
            ProcessPerformancePlugin(),
            "necto.device.performance.metrics"
        )
        let metrics = try #require(output["metrics"]?.arrayValue)

        #expect(metrics.compactMap { $0["id"]?.stringValue } == [
            "cpu", "memory", "fps", "threads", "resident-memory", "compressed-memory",
        ])
    }

    @Test("returns every graphed value in a process snapshot")
    func returnsSnapshot() async throws {
        let output = try await answer(
            ProcessPerformancePlugin(),
            "necto.device.performance.snapshot"
        )
        let snapshot = try #require(output["snapshot"])

        for key in ["cpu", "memoryMB", "fps", "threads", "residentMemoryMB", "compressedMemoryMB"] {
            #expect(snapshot[key]?.numberValue != nil)
        }
        #expect(snapshot["thermalState"]?.stringValue != nil)
        #expect(snapshot["timestamp"]?.numberValue != nil)
    }
}
