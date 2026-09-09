//
//  Copyright (c) 2026 Viva Republica, Inc.
//

// Older SDKs import the read-only task port as an unannotated mutable C global.
@preconcurrency import Darwin
import NectoDefaultPlugins
import NectoModel
import NectoSDK
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// The Performance plugin with process sampling wired in.
///
/// Sampling starts while `performance.observe` has a subscriber and stops with the
/// last subscriber. Linking the SDK product does not start sampling.
public final class ProcessPerformancePlugin: NectoPluginable, NectoPerformanceReporting, @unchecked Sendable {
    public let performance: DefaultPerformancePlugin

    public var id: String { performance.id }
    public var panel: NectoPluginPanel? { performance.panel }

    public init(metrics: [NectoMetric] = []) {
        performance = DefaultPerformancePlugin(metrics: metrics, sampler: NectoProcessSampler())
    }

    public func register(_ necto: NectoHandler) {
        performance.register(necto)
    }

    public func report(_ value: Double, for metricID: String) {
        performance.report(value, for: metricID)
    }
}

private final class NectoProcessSampler: NectoPerformanceSampling, @unchecked Sendable {
    let metrics = [
        NectoMetric(id: "cpu", title: "CPU", unit: "%", budget: .atMost(80)),
        NectoMetric(id: "memory", title: "Memory", unit: "MB"),
        NectoMetric(id: "fps", title: "Frame rate", unit: "fps", budget: .atLeast(55)),
        NectoMetric(id: "threads", title: "Threads", unit: ""),
        NectoMetric(id: "resident-memory", title: "Resident memory", unit: "MB"),
        NectoMetric(id: "compressed-memory", title: "Compressed memory", unit: "MB"),
    ]

    #if canImport(UIKit)
    private let frames = NectoFrameRateMonitor()
    #endif

    func start() async {
        #if canImport(UIKit)
        await frames.start()
        #endif
    }

    func stop() async {
        #if canImport(UIKit)
        await frames.stop()
        #endif
    }

    func snapshot() async -> NectoPerformanceReading {
        let memory = Self.memoryInfo()
        let process = Self.cpuAndThreadCount()
        #if canImport(UIKit)
        let fps = await frames.framesPerSecond
        #else
        let fps = 0.0
        #endif

        let footprint = memory.map { Self.megabytes($0.phys_footprint) } ?? 0
        let resident = memory.map { Self.megabytes($0.resident_size) } ?? 0
        let compressed = memory.map { Self.megabytes($0.compressed) } ?? 0
        let values = [
            "cpu": process.cpu,
            "memory": footprint,
            "fps": fps,
            "threads": Double(process.threads),
            "resident-memory": resident,
            "compressed-memory": compressed,
        ]

        return NectoPerformanceReading(
            values: values,
            snapshot: [
                "cpu": .number(process.cpu),
                "memoryMB": .number(footprint),
                "fps": .number(fps),
                "threads": .number(Double(process.threads)),
                "residentMemoryMB": .number(resident),
                "compressedMemoryMB": .number(compressed),
                "thermalState": .string(Self.thermalState),
                "timestamp": .number(Date().timeIntervalSince1970 * 1000),
            ]
        )
    }

    func detail() async -> NectoJSONValue {
        guard let info = Self.memoryInfo() else { return ["available": .bool(false)] }
        return [
            "available": .bool(true),
            "physicalFootprintMB": .number(Self.megabytes(info.phys_footprint)),
            "residentSizeMB": .number(Self.megabytes(info.resident_size)),
            "virtualSizeMB": .number(Self.megabytes(info.virtual_size)),
            "compressedMB": .number(Self.megabytes(info.compressed)),
        ]
    }

    private static func memoryInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static func cpuAndThreadCount() -> (cpu: Double, threads: Int) {
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS,
              let threads else { return (0, 0) }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: threads),
                vm_size_t(MemoryLayout<thread_t>.stride * Int(threadCount))
            )
        }

        var total = 0.0
        for index in 0 ..< Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return ((total * 10).rounded() / 10, Int(threadCount))
    }

    private static func megabytes<T: BinaryInteger>(_ bytes: T) -> Double {
        (Double(bytes) / 1_048_576 * 10).rounded() / 10
    }

    private static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

#if canImport(UIKit)
private final class NectoFrameRateMonitor: NSObject, @unchecked Sendable {
    @MainActor private var displayLink: CADisplayLink?
    @MainActor private var firstTimestamp: CFTimeInterval?
    @MainActor private var frames = 0
    @MainActor private(set) var framesPerSecond = 0.0

    @MainActor
    func start() {
        stop()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @MainActor
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        firstTimestamp = nil
        frames = 0
        framesPerSecond = 0
    }

    @MainActor @objc private func tick(_ link: CADisplayLink) {
        guard let firstTimestamp else {
            self.firstTimestamp = link.timestamp
            return
        }
        frames += 1
        let elapsed = link.timestamp - firstTimestamp
        guard elapsed >= 1 else { return }
        framesPerSecond = Double(frames) / elapsed
        frames = 0
        self.firstTimestamp = link.timestamp
    }
}
#endif
