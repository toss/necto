//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoDefaultPlugins
import NectoModel
import Foundation
import Testing

@testable import NectoSDK

/// Runs a plugin's registration the way the runtime does, so a test can call what it
/// registered without a socket.
private func handlers(of plugin: any NectoPluginable) -> [String: NectoHandler.Registration] {
    let collector = NectoHandler()
    plugin.register(collector)
    return collector.registrations
}

private func answer(
    _ plugin: any NectoPluginable,
    _ key: String,
    _ input: NectoJSONValue = [:]
) async throws -> NectoJSONValue {
    guard case let .once(body)? = handlers(of: plugin)["\(key)@1"]?.body else {
        throw NectoBridgeError(code: .operationUnavailable, message: key)
    }
    return try await body(input)
}

private final class TestPerformanceSampler: NectoPerformanceSampling, @unchecked Sendable {
    let metrics = [NectoMetric(id: "automatic", title: "Automatic", unit: "")]

    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var active = 0

    var counts: (starts: Int, stops: Int, active: Int) {
        lock.withLock { (starts, stops, active) }
    }

    func start() async {
        lock.withLock {
            starts += 1
            active += 1
        }
    }

    func stop() async {
        lock.withLock { stops += 1 }
        try? await Task.detached {
            try await Task.sleep(for: .milliseconds(100))
        }.value
        lock.withLock { active -= 1 }
    }

    func snapshot() async -> NectoPerformanceReading {
        NectoPerformanceReading(values: ["automatic": 1], snapshot: ["automatic": 1])
    }

    func detail() async -> NectoJSONValue { [:] }
}

private func eventually(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    for _ in 0 ..< 100 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

@Suite("Events plugin")
struct NectoEventsPluginTests {
    private func plugin(_ events: [NectoEvent]) -> NectoEventsPlugin {
        let plugin = NectoEventsPlugin()
        for event in events { plugin.report(event) }
        return plugin
    }

    @Test("reads newest first")
    func newestFirst() async throws {
        let subject = plugin([
            NectoEvent(level: .info, tag: "Auth", message: "first"),
            NectoEvent(level: .info, tag: "Auth", message: "second"),
        ])

        let output = try await answer(subject, "necto.device.events.list")
        let messages = output["events"]?.arrayValue?.compactMap { $0["message"]?.stringValue }
        #expect(messages == ["second", "first"])
    }

    @Test("filters to one level")
    func filtersByLevel() async throws {
        let subject = plugin([
            NectoEvent(level: .debug, tag: "Store", message: "hydrated"),
            NectoEvent(level: .error, tag: "Session", message: "token refresh failed"),
        ])

        let output = try await answer(subject, "necto.device.events.list", ["level": .string("error")])
        #expect(output["events"]?.arrayValue?.count == 1)
    }

    /// A list of five thousand events should not carry five thousand dictionaries, so
    /// the detail lives behind its own call and the row only says whether there is one.
    @Test("keeps detail out of the list and behind its own call")
    func detailIsSeparate() async throws {
        let event = NectoEvent(level: .warn, tag: "Cache", message: "evicted", detail: ["freed": "3.2 MB"])
        let subject = plugin([event])

        let row = try #require(try await answer(subject, "necto.device.events.list")["events"]?.arrayValue?.first)
        #expect(row["detail"] == nil)
        #expect(row["hasDetail"] == .bool(true))

        let detail = try await answer(subject, "necto.device.events.detail", ["eventID": .string(event.id)])
        #expect(detail["event"]?["detail"]?["freed"]?.stringValue == "3.2 MB")
    }

    @Test("says so when asked for an event it does not have")
    func unknownEvent() async {
        let subject = NectoEventsPlugin()
        await #expect(throws: NectoBridgeError.self) {
            try await answer(subject, "necto.device.events.detail", ["eventID": .string("nope")])
        }
    }

    /// The app keeps its own log, so it collects from the moment it starts rather than
    /// from the moment someone opens the panel.
    @Test("collects with no host attached")
    func collectsWithoutHost() async throws {
        let subject = plugin([NectoEvent(level: .info, tag: "Boot", message: "started")])

        let output = try await answer(subject, "necto.device.events.list")
        #expect(output["events"]?.arrayValue?.count == 1)
    }

    @Test("empties on request")
    func clearing() async throws {
        let subject = plugin([NectoEvent(level: .info, tag: "Auth", message: "signed in")])

        #expect(handlers(of: subject)["necto.device.events.clear@1"]?.descriptor.kind == .once)

        _ = try await answer(subject, "necto.device.events.clear")
        #expect(try await answer(subject, "necto.device.events.list")["events"]?.arrayValue?.isEmpty == true)
    }

    @Test("declares its operations as the app's own")
    func declaresDeviceContracts() {
        let descriptors = handlers(of: NectoEventsPlugin()).values.map(\.descriptor)
        #expect(descriptors.allSatisfy { $0.binding.type == .device })
        #expect(Set(descriptors.map(\.binding.name)) == [
            "necto.device.events.list", "necto.device.events.detail", "necto.device.events.observe", "necto.device.events.clear",
        ])
    }
}

@Suite("Performance plugin")
struct NectoPerformancePluginTests {
    private let frame = NectoMetric(id: "frame", title: "Frame time", unit: "ms", budget: .atMost(16.7))
    private let memory = NectoMetric(id: "memory", title: "Memory", unit: "MB")

    @Test("describes what it measures, and what counts as too much")
    func describesMetrics() async throws {
        let subject = NectoPerformancePlugin(metrics: [frame, memory])

        let output = try await answer(subject, "necto.device.performance.metrics")
        let described = try #require(output["metrics"]?.arrayValue)
        #expect(described.count == 2)
        #expect(described.first?["budget"] == .number(16.7))
        #expect(described.first?["budgetKind"] == .string("atMost"))
        // Memory has no single right answer, so it claims no budget rather than a made-up one.
        #expect(described.last?["budget"] == nil)
    }

    @Test("keeps a reading and reports it back")
    func keepsReadings() async throws {
        let subject = NectoPerformancePlugin(metrics: [memory])
        subject.report(148, for: "memory")

        let series = try #require(try await answer(subject, "necto.device.performance.series")["series"]?.arrayValue)
        #expect(series.first?["latest"] == .number(148))
        #expect(series.first?["samples"]?.arrayValue?.count == 1)
    }

    /// The judgement is made once, here, rather than in every surface that draws it.
    @Test("says when a reading is over budget")
    func judgesAgainstBudget() async throws {
        let subject = NectoPerformancePlugin(metrics: [frame])

        subject.report(12.0, for: "frame")
        var series = try #require(try await answer(subject, "necto.device.performance.series")["series"]?.arrayValue)
        #expect(series.first?["isOverBudget"] == .bool(false))

        subject.report(21.4, for: "frame")
        series = try #require(try await answer(subject, "necto.device.performance.series")["series"]?.arrayValue)
        #expect(series.first?["isOverBudget"] == .bool(true))
    }

    /// Which side of the line is the wrong side is the metric's to say. Sixty frames a
    /// second is a floor, and a reader who has to know that already is being told nothing.
    @Test("a floor is exceeded by falling under it")
    func judgesAgainstAFloor() async throws {
        let fps = NectoMetric(id: "fps", title: "Frame rate", unit: "fps", budget: .atLeast(55))
        let subject = NectoPerformancePlugin(metrics: [fps])

        let described = try #require(try await answer(subject, "necto.device.performance.metrics")["metrics"]?.arrayValue)
        #expect(described.first?["budget"] == .number(55))
        #expect(described.first?["budgetKind"] == .string("atLeast"))

        subject.report(59.6, for: "fps")
        var series = try #require(try await answer(subject, "necto.device.performance.series")["series"]?.arrayValue)
        #expect(series.first?["isOverBudget"] == .bool(false))

        subject.report(41.2, for: "fps")
        series = try #require(try await answer(subject, "necto.device.performance.series")["series"]?.arrayValue)
        #expect(series.first?["isOverBudget"] == .bool(true))
    }

    @Test("a metric with no budget is never over it")
    func noBudgetNeverOver() async throws {
        let subject = NectoPerformancePlugin(metrics: [memory])
        subject.report(9_000, for: "memory")

        let series = try #require(try await answer(subject, "necto.device.performance.series")["series"]?.arrayValue)
        #expect(series.first?["isOverBudget"] == .bool(false))
    }

    /// A series nobody can label is a line with no meaning, so it is not kept.
    @Test("drops a reading for a metric that was never declared")
    func dropsUndeclared() async throws {
        let subject = NectoPerformancePlugin(metrics: [memory])
        subject.report(1, for: "nothing-like-this")

        let series = try #require(try await answer(subject, "necto.device.performance.series")["series"]?.arrayValue)
        #expect(series.count == 1)
        #expect(series.first?["samples"]?.arrayValue?.isEmpty == true)
    }

    @Test("narrows to one metric when asked")
    func filtersToOneMetric() async throws {
        let subject = NectoPerformancePlugin(metrics: [frame, memory])

        let output = try await answer(subject, "necto.device.performance.series", ["metricID": .string("frame")])
        #expect(output["series"]?.arrayValue?.count == 1)
    }

    @Test("stays bounded on a long session")
    func staysBounded() async throws {
        let subject = NectoPerformancePlugin(metrics: [memory])
        for index in 0 ..< (NectoPerformancePlugin.capacity + 50) {
            subject.report(Double(index), for: "memory")
        }

        let output = try await answer(subject, "necto.device.performance.series", ["limit": .number(10_000)])
        let samples = try #require(output["series"]?.arrayValue?.first?["samples"]?.arrayValue)
        #expect(samples.count == NectoPerformancePlugin.capacity)
        // The newest survive: a trend is read from where it ended up.
        #expect(samples.last?["value"] == .number(Double(NectoPerformancePlugin.capacity + 49)))
    }

    @Test("declares process monitoring without changing custom metric adoption")
    func declaresMonitoringContracts() {
        let names = handlers(of: NectoPerformancePlugin(metrics: [memory])).values.map(\.descriptor.binding.name)
        #expect(Set(names) == [
            "necto.device.performance.metrics", "necto.device.performance.series",
            "necto.device.performance.observe", "necto.device.performance.snapshot",
            "necto.device.performance.memory",
        ])
    }

    @Test("process operations stay unavailable without an injected sampler")
    func processMetricsAreOptIn() async {
        let subject = NectoPerformancePlugin(metrics: [memory])
        await #expect(throws: NectoBridgeError.self) {
            try await answer(subject, "necto.device.performance.snapshot")
        }
    }

    @Test("a subscription arriving during stop gets a fresh sampler")
    func restartsAfterStopWithoutCancellingTheNewRun() async throws {
        let sampler = TestPerformanceSampler()
        let subject = NectoPerformancePlugin(sampler: sampler)
        guard case let .stream(body)? = handlers(of: subject)["necto.device.performance.observe@1"]?.body else {
            Issue.record("performance.observe is not a stream")
            return
        }
        let out = NectoHandler.Out(yield: { _ in })

        let first = Task { try await body(["interval": 0.1], out) }
        #expect(await eventually { sampler.counts.starts == 1 })

        first.cancel()
        #expect(await eventually { sampler.counts.stops == 1 })

        let second = Task { try await body(["interval": 0.1], out) }
        #expect(await eventually { sampler.counts.starts == 2 })
        _ = try? await first.value
        #expect(sampler.counts.active == 1)

        second.cancel()
        _ = try? await second.value
        #expect(await eventually { sampler.counts.stops == 2 && sampler.counts.active == 0 })
    }
}
