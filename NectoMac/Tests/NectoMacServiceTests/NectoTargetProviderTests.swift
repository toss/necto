//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoMacService

private let connected = NectoTargetSummary(
    target: NectoTarget(deviceID: "device-1", appBundleID: "com.example.app"),
    name: "iPhone",
    appName: "Example",
    appBundleID: "com.example.app",
    deviceType: "device",
    isConnected: true,
    nectoVersion: "0.1.0"
)

private let discovered = NectoTargetSummary(
    target: NectoTarget(deviceID: "device-2", appBundleID: "com.example.other"),
    name: "iPad",
    appName: "Other",
    appBundleID: "com.example.other",
    deviceType: "device",
    isConnected: false
)

private struct StubSource: NectoTargetSource {
    let summaries: [NectoTargetSummary]

    var targets: [NectoTargetSummary] { get async { summaries } }

    func updates() async -> AsyncStream<[NectoTargetSummary]> {
        AsyncStream { continuation in
            continuation.yield(summaries)
            continuation.finish()
        }
    }
}

private func makeContext(pluginID: String = "network-logger") -> NectoInvocationContext {
    NectoInvocationContext(
        principal: NectoPluginPrincipal(pluginID: pluginID, sourceIdentity: "builtin"),
        target: nil
    )
}

@Test func listsOnlyConnectedTargetsByDefault() async throws {
    let provider = NectoTargetsListProvider(
        source: StubSource(summaries: [connected, discovered]),
        handles: NectoTargetHandles()
    )

    let result = try await provider.invoke(input: .object([:]), context: makeContext())
    let targets = try #require(result["targets"]?.arrayValue)

    #expect(targets.count == 1)
    #expect(targets.first?["appName"]?.stringValue == "Example")
}

@Test func includesDiscoveredTargetsWhenAsked() async throws {
    let provider = NectoTargetsListProvider(
        source: StubSource(summaries: [connected, discovered]),
        handles: NectoTargetHandles()
    )

    let result = try await provider.invoke(input: ["includeDiscovered": true], context: makeContext())
    #expect(result["targets"]?.arrayValue?.count == 2)
}

@Test func neverExposesARawDeviceID() async throws {
    // A plugin addresses a target through the handle it was given. Leaking a device id
    // would let it name something it was never shown.
    let provider = NectoTargetsListProvider(
        source: StubSource(summaries: [connected]),
        handles: NectoTargetHandles()
    )

    let result = try await provider.invoke(input: .object([:]), context: makeContext())
    let target = try #require(result["targets"]?.arrayValue?.first?.objectValue)

    #expect(target["targetHandle"] != nil)
    #expect(target["deviceID"] == nil)
    #expect(!target.values.contains(.string("device-1")))
}

@Test func handlesDifferPerPlugin() async throws {
    // Two plugins looking at the same app hold different values, so one cannot use a
    // handle it learned from the other.
    let handles = NectoTargetHandles()
    let provider = NectoTargetsListProvider(source: StubSource(summaries: [connected]), handles: handles)

    let first = try await provider.invoke(input: .object([:]), context: makeContext(pluginID: "first"))
    let second = try await provider.invoke(input: .object([:]), context: makeContext(pluginID: "second"))

    let firstHandle = first["targets"]?.arrayValue?.first?["targetHandle"]?.stringValue
    let secondHandle = second["targets"]?.arrayValue?.first?["targetHandle"]?.stringValue

    #expect(firstHandle != nil)
    #expect(firstHandle != secondHandle)
}

@Test func handlesAreStableForOnePlugin() async throws {
    // A plugin compares handles it received at different times, so they must not churn.
    let handles = NectoTargetHandles()
    let provider = NectoTargetsListProvider(source: StubSource(summaries: [connected]), handles: handles)
    let context = makeContext()

    let first = try await provider.invoke(input: .object([:]), context: context)
    let second = try await provider.invoke(input: .object([:]), context: context)

    #expect(
        first["targets"]?.arrayValue?.first?["targetHandle"]
            == second["targets"]?.arrayValue?.first?["targetHandle"]
    )
}

@Test func resolvesOnlyItsOwnHandles() async {
    let handles = NectoTargetHandles()
    let mine = NectoPluginPrincipal(pluginID: "first", sourceIdentity: "builtin")
    let theirs = NectoPluginPrincipal(pluginID: "second", sourceIdentity: "builtin")

    let handle = await handles.handle(for: connected.target, principal: mine)

    #expect(await handles.target(for: handle, principal: mine) == connected.target)
    #expect(await handles.target(for: handle, principal: theirs) == nil)
    #expect(await handles.target(for: "made-up", principal: mine) == nil)
}

@Test func observeStreamsTheFullList() async throws {
    let provider = NectoTargetsObserveProvider(
        source: StubSource(summaries: [connected, discovered]),
        handles: NectoTargetHandles()
    )

    let stream = try await provider.subscribe(input: .object([:]), context: makeContext())

    var snapshots: [NectoJSONValue] = []
    for try await snapshot in stream { snapshots.append(snapshot) }

    #expect(snapshots.count == 1)
    #expect(snapshots.first?["targets"]?.arrayValue?.count == 1)
}
