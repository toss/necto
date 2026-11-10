//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoEventsPlugin
import NectoModel
import NectoNetworkPlugin
import NectoPerformancePlugin
import Testing

@testable import NectoSDK

@Suite
struct NectoDataPluginUsageTests {
    private let record = NectoNetworkRecord(
        id: "fixture-request",
        method: "POST",
        url: "https://example.com/orders?reference=fixture-order",
        startedAtMilliseconds: 0,
        state: .failed,
        errorSummary: "Fixture order rejected",
        requestHeaders: ["X-Order": "fixture-order"]
    )
    private let event = NectoEvent(
        id: "fixture-event",
        level: .warn,
        tag: "Fixture",
        message: "Fixture note",
        detail: ["order": "fixture-order"]
    )

    @Test
    func networkOperations() async throws {
        let plugin = NectoNetworkPlugin()
        let usage = PluginUsageRecorder()
        let registrar = usage.register(plugin)
        plugin.report(record)
        #expect(usage.events.isEmpty)

        let page = try await usage.call(registrar, "network-records.list", input: ["limit": 1])
        #expect(page["records"]?.arrayValue?.first?["url"] == .string(record.url))
        let detail = try await usage.call(
            registrar,
            "network-records.detail",
            input: ["recordID": .string(record.id)]
        )
        #expect(detail["record"]?["requestHeaders"]?["X-Order"] == "fixture-order")
        #expect(try await usage.call(registrar, "network-records.clear") == ["cleared": true])

        let error = await #expect(throws: NectoBridgeError.self) {
            try await usage.call(registrar, "network-records.detail", input: ["recordID": .string(record.id)])
        }
        #expect(error == NectoBridgeError(code: .operationUnavailable, message: "No record '\(record.id)'"))
        #expect(usage.events == [
            .init(name: "network.operation", params: ["operation": "list", "result": "success"]),
            .init(name: "network.operation", params: ["operation": "detail", "result": "success"]),
            .init(name: "network.operation", params: ["operation": "clear", "result": "success"]),
            .init(name: "network.operation", params: ["operation": "detail", "result": "failure"]),
        ])
    }

    @Test
    func eventsOperations() async throws {
        let plugin = NectoEventsPlugin()
        let usage = PluginUsageRecorder()
        let registrar = usage.register(plugin)
        plugin.report(event)
        #expect(usage.events.isEmpty)

        let page = try await usage.call(registrar, "events.list", input: ["limit": 1, "level": "warn"])
        #expect(page["events"]?.arrayValue?.first?["message"] == .string(event.message))
        let detail = try await usage.call(registrar, "events.detail", input: ["eventID": .string(event.id)])
        #expect(detail["event"]?["detail"]?["order"] == "fixture-order")

        let error = await #expect(throws: NectoBridgeError.self) {
            try await usage.call(registrar, "events.detail")
        }
        #expect(error == NectoBridgeError(code: .invalidInput, message: "eventID is required"))
        #expect(try await usage.call(registrar, "events.clear") == ["cleared": true])
        #expect(usage.events == [
            .init(name: "events.operation", params: ["operation": "list", "result": "success"]),
            .init(name: "events.operation", params: ["operation": "detail", "result": "success"]),
            .init(name: "events.operation", params: ["operation": "detail", "result": "failure"]),
            .init(name: "events.operation", params: ["operation": "clear", "result": "success"]),
        ])
    }

    @Test
    func performanceOperations() async throws {
        let plugin = NectoPerformancePlugin(sampler: UsagePerformanceSampler())
        let usage = PluginUsageRecorder()
        let registrar = usage.register(plugin)
        plugin.report(148, for: "fixture-metric")

        let metadata = try await usage.call(registrar, "performance.metrics")
        #expect(metadata["metrics"]?.arrayValue?.first?["id"] == "fixture-metric")
        #expect(usage.events.isEmpty)

        let series = try await usage.call(
            registrar,
            "performance.series",
            input: ["metricID": "fixture-metric", "limit": 1]
        )
        #expect(series["series"]?.arrayValue?.first?["latest"] == 148)
        #expect(try await usage.call(registrar, "performance.snapshot") == ["snapshot": ["fixtureProcess": 192]])
        #expect(try await usage.call(registrar, "performance.memory") == ["memory": ["fixtureMemory": 256]])
        #expect(usage.events == [
            .init(name: "performance.operation", params: ["operation": "series", "result": "success"]),
            .init(name: "performance.operation", params: ["operation": "snapshot", "result": "success"]),
            .init(name: "performance.operation", params: ["operation": "memory", "result": "success"]),
        ])
    }

    @Test(arguments: ["snapshot", "memory"])
    func performanceWithoutSampler(_ operation: String) async {
        let usage = PluginUsageRecorder()
        let registrar = usage.register(NectoPerformancePlugin(metrics: []))

        let error = await #expect(throws: NectoBridgeError.self) {
            try await usage.call(registrar, "performance.\(operation)")
        }
        #expect(error == NectoBridgeError(code: .operationUnavailable, message: "Process metrics were not enabled"))
        #expect(usage.events == [
            .init(name: "performance.operation", params: ["operation": .string(operation), "result": "failure"]),
        ])
    }

    @Test
    func networkSubscription() async throws {
        let plugin = NectoNetworkPlugin()
        try await verifySubscription(
            plugin,
            operation: "network-records.observe",
            eventName: "network.subscription_started"
        ) {
            plugin.report(record)
            plugin.report(record)
        }
    }

    @Test
    func eventsSubscription() async throws {
        let plugin = NectoEventsPlugin()
        try await verifySubscription(
            plugin,
            operation: "events.observe",
            eventName: "events.subscription_started"
        ) {
            plugin.report(event)
            plugin.report(event)
        }
    }

    @Test
    func performanceSubscription() async throws {
        let sampler = UsagePerformanceSampler()
        let plugin = NectoPerformancePlugin(sampler: sampler)
        try await verifySubscription(
            plugin,
            operation: "performance.observe",
            eventName: "performance.subscription_started",
            input: ["interval": 60]
        ) {
            plugin.report(148, for: "fixture-metric")
        }
    }

    private func verifySubscription(
        _ plugin: any NectoPlugin,
        operation: String,
        eventName: String,
        input: NectoJSONValue = [:],
        report: () -> Void
    ) async throws {
        let usage = PluginUsageRecorder()
        let registrar = usage.register(plugin)
        guard case let .stream(body)? = registrar.registrations["necto.device.\(operation)@1"]?.body else {
            Issue.record("\(operation) is not a stream")
            return
        }
        let expected: [RecordedPluginUsage] = [.init(name: eventName, params: [:])]
        let deliveries = StreamDeliveries()
        let out = NectoRegistrar.Out { _ in await deliveries.received() }
        let task = Task { try await body(input, out) }
        defer { task.cancel() }

        try await waitUntil { !usage.events.isEmpty }
        #expect(usage.events == expected)

        report()
        try await waitUntil { await deliveries.count == 2 }

        task.cancel()
        _ = await task.result
        #expect(usage.events == expected)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !(await condition()) {
            try #require(clock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor StreamDeliveries {
    private(set) var count = 0

    func received() { count += 1 }
}

private final class UsagePerformanceSampler: NectoPerformanceSampling {
    let metrics = [NectoMetric(id: "fixture-metric", title: "Fixture Metric", unit: "MB")]

    func start() async {}
    func stop() async {}

    func snapshot() async -> NectoPerformanceReading {
        NectoPerformanceReading(values: ["fixture-metric": 192], snapshot: ["fixtureProcess": 192])
    }

    func detail() async -> NectoJSONValue { ["fixtureMemory": 256] }
}
