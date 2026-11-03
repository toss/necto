//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoProcessMetricPlugin
import Foundation
import Testing

@testable import NectoSDK

private func answer(
    _ plugin: any NectoPlugin,
    _ key: String,
    _ input: NectoJSONValue = [:]
) async throws -> NectoJSONValue {
    let collector = NectoRegistrar()
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

    /// Listing a task's threads hands over a port for each one. A port that is not
    /// given back outlives its thread as a dead name, one per thread ever sampled.
    @Test("gives back the thread ports a sample was handed")
    func releasesThreadPorts() async throws {
        let plugin = ProcessPerformancePlugin()
        _ = try await answer(plugin, "necto.device.performance.snapshot")
        let before = portNameCount()

        for _ in 0..<300 {
            let thread = ParkedThread()
            _ = try await answer(plugin, "necto.device.performance.snapshot")
            thread.end()
        }

        #expect(portNameCount() - before < 100)
    }
}

/// A thread that stays alive until it is told to end.
private final class ParkedThread: @unchecked Sendable {
    private let leave = DispatchSemaphore(value: 0)
    private let left = DispatchSemaphore(value: 0)

    init() {
        Thread.detachNewThread { [leave, left] in
            leave.wait()
            left.signal()
        }
    }

    func end() {
        leave.signal()
        left.wait()
    }
}

/// How many port names this process holds, dead ones included.
private func portNameCount() -> Int {
    var names: mach_port_name_array_t?
    var nameCount: mach_msg_type_number_t = 0
    var types: mach_port_type_array_t?
    var typeCount: mach_msg_type_number_t = 0
    guard mach_port_names(mach_task_self_, &names, &nameCount, &types, &typeCount) == KERN_SUCCESS else { return 0 }
    if let names {
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: names),
            vm_size_t(MemoryLayout<mach_port_name_t>.stride * Int(nameCount))
        )
    }
    if let types {
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: types),
            vm_size_t(MemoryLayout<mach_port_type_t>.stride * Int(typeCount))
        )
    }
    return Int(nameCount)
}
