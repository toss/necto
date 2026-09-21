//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoSDK
import Foundation

/// One reading of one thing, at one moment.
public struct NectoSample: Sendable, Hashable {
    public let at: Date
    public let value: Double

    public init(at: Date = Date(), value: Double) {
        self.at = at
        self.value = value
    }
}

/// Something worth watching over time.
///
/// A metric knows what it measures and what counts as too much, because "21.4" means
/// nothing without both. The budget is what turns a number into a judgement.
public struct NectoMetric: Sendable, Hashable, Identifiable {
    /// The line a metric should stay on the right side of — and which side that is,
    /// because it is not the same for every metric. Sixty frames a second is a floor;
    /// eighty percent of a CPU is a ceiling.
    public enum Budget: Sendable, Hashable {
        case atMost(Double)
        case atLeast(Double)

        public var limit: Double {
            switch self {
            case let .atMost(limit), let .atLeast(limit): limit
            }
        }

        var isCeiling: Bool {
            if case .atMost = self { return true }
            return false
        }

        func isExceeded(by value: Double) -> Bool {
            switch self {
            case let .atMost(limit): value > limit
            case let .atLeast(limit): value < limit
            }
        }
    }

    public let id: String
    public let title: String
    /// Shown after the value: `MB`, `fps`, `%`.
    public let unit: String
    /// The line this metric should stay on the right side of, when it has one. Memory
    /// usually has no single right answer, so it claims none.
    public let budget: Budget?

    public init(id: String, title: String, unit: String, budget: Budget? = nil) {
        self.id = id
        self.title = title
        self.unit = unit
        self.budget = budget
    }
}

/// Somewhere to send readings.
///
/// The app can report domain metrics itself or inject an optional sampler. Both
/// become the same bounded series here.
public protocol NectoPerformanceReporting: AnyObject, Sendable {
    func report(_ value: Double, for metricID: String)
}

/// One batch produced by an optional performance sampler.
///
/// `values` feed the time series. `snapshot` is returned as-is from
/// `performance.snapshot`, so details that do not belong on a graph remain opaque to
/// the plugin.
public struct NectoPerformanceReading: Sendable {
    public let values: [String: Double]
    public let snapshot: NectoJSONValue

    public init(values: [String: Double], snapshot: NectoJSONValue) {
        self.values = values
        self.snapshot = snapshot
    }
}

/// An optional source of automatic readings.
///
/// Implementations live in separate modules so an app only links the capture
/// mechanism it chooses.
public protocol NectoPerformanceSampling: AnyObject, Sendable {
    var metrics: [NectoMetric] { get }
    func start() async
    func stop() async
    func snapshot() async -> NectoPerformanceReading
    func detail() async -> NectoJSONValue
}

/// What the app is spending, read from Necto.
///
/// ```swift
/// let performance = NectoPerformancePlugin(metrics: [
///     NectoMetric(id: "memory", title: "Memory", unit: "MB"),
///     NectoMetric(id: "frame", title: "Frame time", unit: "ms", budget: 16.7),
/// ])
/// NectoSDK.register(performance)
///
/// performance.report(148, for: "memory")
/// ```
public final class NectoPerformancePlugin: NectoPluginable, NectoPerformanceReporting, @unchecked Sendable {
    /// About twenty minutes at one reading a second. Enough to see a trend, bounded
    /// enough that an app running all day does not grow without limit.
    public static let capacity = 1200

    public let id = "performance-monitor"

    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module, subdirectory: "Panels/performance-monitor") }

    private let metrics: [NectoMetric]
    private let sampler: (any NectoPerformanceSampling)?
    private let monitor: NectoPerformanceMonitor?
    private let lock = NSLock()
    private var samples: [String: [NectoSample]] = [:]
    private var listeners: [UUID: NectoHandler.Out] = [:]

    public init(metrics: [NectoMetric]) {
        self.metrics = metrics
        sampler = nil
        monitor = nil
    }

    public init(metrics: [NectoMetric] = [], sampler: any NectoPerformanceSampling) {
        let automaticMetrics = sampler.metrics.filter { metric in
            !metrics.contains(where: { $0.id == metric.id })
        }
        self.metrics = metrics + automaticMetrics
        self.sampler = sampler
        monitor = NectoPerformanceMonitor(sampler: sampler)
    }

    public func register(_ necto: NectoHandler) {
        necto.handle("performance.metrics") { [self] _ in
            ["metrics": .array(metrics.map(Self.describe))]
        }

        necto.handle("performance.series") { [self] input in
            let limit = Int(input["limit"]?.numberValue ?? 120)
            let wanted = input["metricID"]?.stringValue

            let series = metrics
                .filter { wanted == nil || $0.id == wanted }
                .map { metric -> NectoJSONValue in
                    let taken = lock.withLock { Array((samples[metric.id] ?? []).suffix(limit)) }
                    return .object([
                        "metricID": .string(metric.id),
                        "samples": .array(taken.map(Self.encode)),
                        // Said here rather than left to the reader: the same summary
                        // computed in three plugins is three chances to disagree.
                        "latest": taken.last.map { .number($0.value) } ?? .null,
                        "isOverBudget": .bool(Self.isOver(taken.last?.value, metric.budget)),
                    ])
                }

            return ["series": .array(series)]
        }

        necto.handle("performance.observe") { [self] input, out in
            let token = UUID()
            lock.withLock {
                listeners[token] = out
            }
            if let monitor {
                let interval = min(max(input["interval"]?.numberValue ?? 1, 0.1), 60)
                await monitor.add(token: token, interval: interval) { [weak self] reading in
                    self?.receive(reading)
                }
            }

            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                }
            } catch is CancellationError {
                // Cancellation is how the bridge ends a subscription.
            }

            lock.withLock { _ = listeners.removeValue(forKey: token) }
            await monitor?.remove(token: token)
        }

        necto.handle("performance.snapshot") { [self] _ in
            guard let sampler else {
                throw NectoBridgeError(code: .operationUnavailable, message: "Process metrics were not enabled")
            }
            let reading = await sampler.snapshot()
            receive(reading)
            return ["snapshot": reading.snapshot]
        }

        necto.handle("performance.memory") { [self] _ in
            guard let sampler else {
                throw NectoBridgeError(code: .operationUnavailable, message: "Process metrics were not enabled")
            }
            return ["memory": await sampler.detail()]
        }
    }

    /// Records one reading. A value for a metric that was never declared is dropped:
    /// a series nobody can label is a line with no meaning.
    public func report(_ value: Double, for metricID: String) {
        guard let metric = metrics.first(where: { $0.id == metricID }) else { return }

        let sample = NectoSample(value: value)
        let out = lock.withLock { () -> [NectoHandler.Out] in
            samples[metricID, default: []].append(sample)
            if samples[metricID]!.count > Self.capacity {
                samples[metricID]!.removeFirst(samples[metricID]!.count - Self.capacity)
            }
            return Array(listeners.values)
        }

        let payload: NectoJSONValue = [
            "metricID": .string(metricID),
            "sample": Self.encode(sample),
            "isOverBudget": .bool(Self.isOver(value, metric.budget)),
        ]
        for listener in out {
            Task { await listener.send(payload) }
        }
    }

    private func receive(_ reading: NectoPerformanceReading) {
        for (metricID, value) in reading.values {
            report(value, for: metricID)
        }
    }

    // MARK: Coding

    static func describe(_ metric: NectoMetric) -> NectoJSONValue {
        var fields: [String: NectoJSONValue] = [
            "id": .string(metric.id),
            "title": .string(metric.title),
            "unit": .string(metric.unit),
        ]
        if let budget = metric.budget {
            fields["budget"] = .number(budget.limit)
            // Which side of the line is the wrong side. Without it a reader has to
            // already know the metric to know whether 55 fps is good news.
            fields["budgetKind"] = .string(budget.isCeiling ? "atMost" : "atLeast")
        }
        return .object(fields)
    }

    static func encode(_ sample: NectoSample) -> NectoJSONValue {
        ["at": .number(sample.at.timeIntervalSince1970 * 1000), "value": .number(sample.value)]
    }

    static func isOver(_ value: Double?, _ budget: NectoMetric.Budget?) -> Bool {
        guard let value, let budget else { return false }
        return budget.isExceeded(by: value)
    }
}

private actor NectoPerformanceMonitor {
    private let sampler: any NectoPerformanceSampling
    private var subscriptions: [UUID: Double] = [:]
    private var receive: (@Sendable (NectoPerformanceReading) -> Void)?
    private var generation = 0
    private var running: (generation: Int, task: Task<Void, Never>)?

    init(sampler: any NectoPerformanceSampling) {
        self.sampler = sampler
    }

    func add(
        token: UUID,
        interval: Double,
        receive: @escaping @Sendable (NectoPerformanceReading) -> Void
    ) {
        subscriptions[token] = interval
        self.receive = receive
        guard running == nil else { return }
        start(interval: interval, receive: receive)
    }

    func remove(token: UUID) async {
        subscriptions.removeValue(forKey: token)
        guard subscriptions.isEmpty, let running else { return }

        running.task.cancel()
        await running.task.value
        if self.running?.generation == running.generation {
            self.running = nil
        }

        if let interval = subscriptions.values.min(),
           let receive,
           self.running == nil {
            start(interval: interval, receive: receive)
        }
    }

    private func start(
        interval: Double,
        receive: @escaping @Sendable (NectoPerformanceReading) -> Void
    ) {
        generation += 1
        let current = generation
        let sampler = sampler
        let task = Task {
            await sampler.start()
            while !Task.isCancelled {
                receive(await sampler.snapshot())
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
            }
            await sampler.stop()
        }
        running = (current, task)
    }
}
