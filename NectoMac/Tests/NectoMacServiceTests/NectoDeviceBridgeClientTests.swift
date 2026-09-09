//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoMacService

private let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")

/// Stands in for a connected app: records what the host sent and lets a test answer
/// as the app would.
private final class FakeApp: NectoDeviceMessenger, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [NectoEnvelope] = []
    var failSend: (any Error)?

    func send(_ envelope: NectoEnvelope, to _: NectoTarget) async throws {
        if let failSend { throw failSend }
        lock.withLock { sent.append(envelope) }
    }

    var envelopes: [NectoEnvelope] { lock.withLock { sent } }

    func invocations() -> [NectoPluginInvocation] {
        envelopes
            .filter { $0.type == .pluginInvoke }
            .compactMap { try? $0.decode(NectoPluginInvocation.self) }
    }

    func cancels() -> [NectoPluginCancel] {
        envelopes
            .filter { $0.type == .pluginCancel }
            .compactMap { try? $0.decode(NectoPluginCancel.self) }
    }

    /// Waits for the host to have sent an invocation, since it is sent from a task.
    func firstInvocation() async throws -> NectoPluginInvocation {
        for _ in 0 ..< 100 {
            if let first = invocations().first { return first }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NectoBridgeError(code: .timeout, message: "no invocation was sent")
    }
}

@Test func invokeTravelsToTheAppAndComesBack() async throws {
    let app = FakeApp()
    let client = NectoDeviceBridgeClient(messenger: app)

    async let output = client.invoke(
        name: "com.example.variables",
        version: 1,
        kind: .once,
        input: ["scope": "all"],
        target: target
    )

    let invocation = try await app.firstInvocation()
    #expect(invocation.name == "com.example.variables")
    #expect(invocation.version == 1)
    #expect(invocation.input["scope"]?.stringValue == "all")

    await client.receive(NectoPluginResult(requestID: invocation.requestID, output: ["count": 3]))
    #expect(try await output == ["count": 3])
}

@Test func invokeSurfacesTheErrorTheAppReturned() async throws {
    let app = FakeApp()
    let client = NectoDeviceBridgeClient(messenger: app)

    let output = Task {
        try await client.invoke(
            name: "com.example.variables",
            version: 1,
            kind: .once,
            input: .object([:]),
            target: target
        )
    }

    let invocation = try await app.firstInvocation()
    await client.receive(NectoPluginResult(
        requestID: invocation.requestID,
        error: NectoBridgeError(code: .providerFailed, message: "the app said no")
    ))

    await #expect(throws: NectoBridgeError.self) { try await output.value }
}

@Test func streamYieldsEventsUntilTheFinalResult() async throws {
    let app = FakeApp()
    let client = NectoDeviceBridgeClient(messenger: app)

    let stream = try await client.subscribe(
        name: "com.example.variables.stream",
        version: 1,
        input: .object([:]),
        target: target
    )
    let invocation = try await app.firstInvocation()
    #expect(invocation.kind == .stream)

    await client.receive(NectoPluginResult(requestID: invocation.requestID, output: ["n": 1], isFinal: false))
    await client.receive(NectoPluginResult(requestID: invocation.requestID, output: ["n": 2], isFinal: false))
    await client.receive(NectoPluginResult(requestID: invocation.requestID))

    var received: [NectoJSONValue] = []
    for try await event in stream { received.append(event) }
    #expect(received == [["n": 1], ["n": 2]])
}

@Test func disconnectFailsCallsStillWaiting() async throws {
    // Without this a plugin waiting on an app that went away hangs until its timeout,
    // which on a stream is forever.
    let app = FakeApp()
    let client = NectoDeviceBridgeClient(messenger: app)

    let output = Task {
        try await client.invoke(
            name: "com.example.variables",
            version: 1,
            kind: .once,
            input: .object([:]),
            target: target
        )
    }
    _ = try await app.firstInvocation()
    await client.targetDisconnected(target)

    await #expect(throws: NectoBridgeError.self) { try await output.value }
}

@Test func disconnectLeavesOtherTargetsAlone() async throws {
    let app = FakeApp()
    let client = NectoDeviceBridgeClient(messenger: app)
    let other = NectoTarget(deviceID: "device-2", appBundleID: "com.example.other")

    async let output = client.invoke(
        name: "com.example.variables",
        version: 1,
        kind: .once,
        input: .object([:]),
        target: target
    )
    let invocation = try await app.firstInvocation()

    await client.targetDisconnected(other)
    await client.receive(NectoPluginResult(requestID: invocation.requestID, output: ["ok": true]))

    #expect(try await output == ["ok": true])
}

@Test func endingASubscriptionCancelsItOnTheApp() async throws {
    let app = FakeApp()
    let client = NectoDeviceBridgeClient(messenger: app)

    var stream: AsyncThrowingStream<NectoJSONValue, any Error>? = try await client.subscribe(
        name: "com.example.variables.stream",
        version: 1,
        input: .object([:]),
        target: target
    )
    let invocation = try await app.firstInvocation()

    // Dropping the stream has to tell the app to stop producing.
    stream = nil
    _ = stream

    for _ in 0 ..< 100 where app.cancels().isEmpty {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(app.cancels().first?.requestID == invocation.requestID)
}

@Test func aSendFailureFailsTheCallRatherThanHanging() async {
    let app = FakeApp()
    app.failSend = NectoBridgeError(code: .targetDisconnected, message: "gone")
    let client = NectoDeviceBridgeClient(messenger: app)

    await #expect(throws: NectoBridgeError.self) {
        try await client.invoke(
            name: "com.example.variables",
            version: 1,
            kind: .once,
            input: .object([:]),
            target: target
        )
    }
}
