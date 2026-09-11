//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoMacService

private let desktopName = "necto.desktop.network-records.list"
private let deviceName = "necto.device.variables.list"

private func makeBinding(
    name: String = desktopName,
    version: Int = 1
) -> NectoBridgeBinding {
    NectoBridgeBinding(name: name, version: version)
}

private struct StubProvider: NectoOperationProvider {
    let descriptor: NectoBridgeDescriptor
    let output: NectoJSONValue

    init(
        binding: NectoBridgeBinding = makeBinding(),
        kind: NectoOperationKind = .once,
        output: NectoJSONValue = ["ok": true]
    ) {
        descriptor = NectoBridgeDescriptor(
            binding: binding,
            kind: kind,
        )
        self.output = output
    }

    func invoke(input _: NectoJSONValue, context _: NectoInvocationContext) async throws -> NectoJSONValue {
        output
    }
}

private func makeManifest(
    pluginID: String = "network-logger",
    binding: NectoBridgeBinding = makeBinding(),
    inputSchema: NectoJSONValue = ["type": "object"],
    outputSchema: NectoJSONValue = ["type": "object"],
    kind: NectoOperationKind = .once,
    version: String = "1.0.0",
    timeoutMs: Int = 1000,
) -> NectoPluginManifest {
    NectoPluginManifest(
        id: pluginID,
        name: "Network Logger",
        description: "Inspect network requests",
        version: version,
        author: "Necto",
        icon: .init(systemName: "network"),
        assets: ["index.html"],
        allowedOrigins: ["self"],
        operations: [
            NectoOperation(
                id: "records.list",
                title: "List",
                description: "Recorded requests",
                kind: kind,
                binding: binding,
                inputSchema: inputSchema,
                outputSchema: outputSchema,
                timeoutMs: timeoutMs
            ),
        ]
    )
}

/// Models a callback API that ignores task cancellation until its callback arrives.
private actor DeferredProvider: NectoOperationProvider {
    nonisolated let descriptor = NectoBridgeDescriptor(binding: makeBinding(), kind: .once)
    private var reply: CheckedContinuation<NectoJSONValue, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private var released = false

    var isWaitingForCallback: Bool { reply != nil && !released }

    func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        if released { return ["ok": true] }
        return await withCheckedContinuation { continuation in
            reply = continuation
            started.forEach { $0.resume() }
            started.removeAll()
        }
    }
    func waitUntilStarted() async {
        if reply != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release() {
        released = true
        reply?.resume(returning: ["ok": true])
        reply = nil
    }
}

@Test func deadlineReturnsBeforeANonCooperativeProviderAndPreventsRetryAccumulation() async throws {
    let registry = makeRegistry()
    let provider = DeferredProvider()
    await registry.registerHostProvider(provider)
    try await registry.install(manifest: makeManifest(timeoutMs: 40), sourceIdentity: "fixture")
    // Bounds a regression without using runner speed to decide whether the callback was awaited.
    let watchdog = Task { try await Task.sleep(for: .seconds(10)); await provider.release() }
    defer { watchdog.cancel() }
    do {
        _ = try await registry.invoke(pluginID: "network-logger", operationID: "records.list", target: nil)
        Issue.record("The invocation did not time out")
    } catch let error as NectoBridgeError {
        #expect(error.code == .timeout)
    }
    try #require(await provider.isWaitingForCallback)
    await registry.registerHostProvider(StubProvider())
    try await registry.install(manifest: makeManifest(pluginID: "another-plugin"), sourceIdentity: "another-fixture")
    let independent = try await registry.invoke(pluginID: "another-plugin", operationID: "records.list", target: nil)
    #expect(independent == ["ok": true])
    do {
        _ = try await registry.invoke(pluginID: "network-logger", operationID: "records.list", target: nil)
        Issue.record("Retry launched while the cancelled provider still owned its work")
    } catch let error as NectoBridgeError {
        #expect(error.code == .operationUnavailable)
    }
    await provider.release()
    let clock = ContinuousClock()
    let until = clock.now + .seconds(1)
    var recovered = false
    while clock.now < until {
        if let value = try? await registry.invoke(pluginID: "network-logger", operationID: "records.list", target: nil) {
            #expect(value == ["ok": true]); recovered = true; break
        }
        await Task.yield()
    }
    #expect(recovered)
}

@Test func callerCancellationReturnsWithoutWaitingForAnUnboundedProvider() async throws {
    let registry = makeRegistry()
    let provider = DeferredProvider()
    await registry.registerHostProvider(provider)
    try await registry.install(manifest: makeManifest(timeoutMs: 0), sourceIdentity: "fixture")
    let pending = Task {
        try await registry.invoke(pluginID: "network-logger", operationID: "records.list", target: nil)
    }
    await provider.waitUntilStarted()
    let watchdog = Task { try await Task.sleep(for: .seconds(10)); await provider.release() }
    defer { watchdog.cancel() }
    pending.cancel()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(await provider.isWaitingForCallback)
    await provider.release()
}

@Test func uninstallCancelsTheReplyWhileTheProviderIsStillFinishing() async throws {
    let registry = makeRegistry()
    let provider = DeferredProvider()
    await registry.registerHostProvider(provider)
    try await registry.install(manifest: makeManifest(timeoutMs: 0), sourceIdentity: "fixture")
    let pending = Task {
        try await registry.invoke(pluginID: "network-logger", operationID: "records.list", target: nil)
    }
    await provider.waitUntilStarted()
    let watchdog = Task { try await Task.sleep(for: .seconds(10)); await provider.release() }
    defer { watchdog.cancel() }
    await registry.uninstall(pluginID: "network-logger")
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(await provider.isWaitingForCallback)
    await provider.release()
}

@Test func keepsDifferentDeviceBuildsOfTheSamePlugin() async throws {
    let registry = makeRegistry()
    let first = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    let second = NectoTarget(deviceID: "device-2", appBundleID: "com.example.app")

    try await registry.installDevice(
        manifest: makeManifest(version: "1.0.0"),
        sourceIdentity: "device:com.example.app",
        for: first
    )
    try await registry.installDevice(
        manifest: makeManifest(version: "2.0.0"),
        sourceIdentity: "device:com.example.app",
        for: second
    )

    #expect(await registry.context(pluginID: "network-logger", target: first)?.pluginVersion == "1.0.0")
    #expect(await registry.context(pluginID: "network-logger", target: second)?.pluginVersion == "2.0.0")

    await registry.uninstallDevice(pluginID: "network-logger", for: first)
    #expect(await registry.context(pluginID: "network-logger", target: first) == nil)
    #expect(await registry.context(pluginID: "network-logger", target: second)?.pluginVersion == "2.0.0")
}

private func makeRegistry() -> NectoPluginRegistry {
    NectoPluginRegistry()
}

private struct LiveStreamProvider: NectoOperationProvider {
    let descriptor: NectoBridgeDescriptor
    let stream: AsyncThrowingStream<NectoJSONValue, any Error>

    func subscribe(input: NectoJSONValue, context: NectoInvocationContext) async throws
        -> AsyncThrowingStream<NectoJSONValue, any Error> { stream }
}

@Test(arguments: [false, true])
func removingAPluginEndsItsActiveSubscription(device: Bool) async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    let binding = makeBinding(name: device ? deviceName : desktopName)
    let pair = AsyncThrowingStream<NectoJSONValue, any Error>.makeStream()
    let provider = LiveStreamProvider(
        descriptor: NectoBridgeDescriptor(binding: binding, kind: .stream), stream: pair.stream)
    let manifest = makeManifest(binding: binding, kind: .stream)
    if device {
        try await registry.installDevice(manifest: manifest, sourceIdentity: "fixture", for: target)
        await registry.setDeviceProviders([provider], for: target, pluginID: manifest.id)
    } else {
        try await registry.install(manifest: manifest, sourceIdentity: "fixture")
        await registry.registerHostProvider(provider)
    }
    let stream = try await registry.subscribe(pluginID: manifest.id, operationID: "records.list",
                                              target: device ? target : nil)
    var iterator = stream.makeAsyncIterator()
    pair.continuation.yield(["ok": true])
    #expect(try await iterator.next() == ["ok": true])
    if device { await registry.uninstallDevice(pluginID: manifest.id, for: target) }
    else { await registry.uninstall(pluginID: manifest.id) }
    // Bounds the regression test when the registry fails to terminate the stream.
    let watchdog = Task { try await Task.sleep(for: .seconds(1)); pair.continuation.finish() }
    defer { watchdog.cancel(); pair.continuation.finish() }
    do {
        _ = try await iterator.next()
        Issue.record("Removing the plugin must cancel its subscription")
    } catch is CancellationError {}
}

private actor DeferredStreamProvider: NectoOperationProvider {
    nonisolated let descriptor = NectoBridgeDescriptor(binding: makeBinding(), kind: .stream)
    let pair = AsyncThrowingStream<NectoJSONValue, any Error>.makeStream()
    private var reply: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func subscribe(input: NectoJSONValue, context: NectoInvocationContext) async throws
        -> AsyncThrowingStream<NectoJSONValue, any Error> {
        await withCheckedContinuation { reply = $0; waiters.forEach { $0.resume() }; waiters.removeAll() }
        return pair.stream
    }

    func waitUntilStarted() async {
        if reply != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() { reply?.resume(); reply = nil; pair.continuation.finish() }
}

@Test(arguments: [false, true])
func subscriptionOpeningCannotSurviveRemovalOrCallerCancellation(remove: Bool) async throws {
    let registry = makeRegistry()
    let provider = DeferredStreamProvider()
    await registry.registerHostProvider(provider)
    try await registry.install(manifest: makeManifest(kind: .stream), sourceIdentity: "fixture")
    let pending = Task {
        try await registry.subscribe(pluginID: "network-logger", operationID: "records.list", target: nil)
    }
    await provider.waitUntilStarted()
    if remove { await registry.uninstall(pluginID: "network-logger") }
    else { pending.cancel() }
    await provider.release()
    await #expect(throws: CancellationError.self) { try await pending.value }
}

@Test func removingOneTargetDoesNotCancelAnotherTargetsSubscription() async throws {
    let registry = makeRegistry()
    let first = NectoTarget(deviceID: "first", appBundleID: "com.example.app")
    let second = NectoTarget(deviceID: "second", appBundleID: "com.example.app")
    let binding = makeBinding(name: deviceName)
    let manifest = makeManifest(binding: binding, kind: .stream)
    let pair = AsyncThrowingStream<NectoJSONValue, any Error>.makeStream()
    defer { pair.continuation.finish() }
    for target in [first, second] {
        try await registry.installDevice(manifest: manifest, sourceIdentity: "fixture", for: target)
    }
    await registry.setDeviceProviders([
        LiveStreamProvider(descriptor: NectoBridgeDescriptor(binding: binding, kind: .stream), stream: pair.stream)
    ], for: second, pluginID: manifest.id)
    let stream = try await registry.subscribe(pluginID: manifest.id, operationID: "records.list", target: second)
    await registry.uninstallDevice(pluginID: manifest.id, for: first)
    pair.continuation.yield(["ok": true])
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == ["ok": true])
    await registry.uninstallDevice(pluginID: manifest.id, for: second)
}

@Test func ambiguousDeviceContractsAreUnavailableUntilTheConflictIsRemoved() async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    let binding = makeBinding(name: deviceName)
    try await registry.install(manifest: makeManifest(binding: binding), sourceIdentity: "builtin")
    await registry.setDeviceProviders([StubProvider(binding: binding)], for: target, pluginID: "first")
    await registry.setDeviceProviders([StubProvider(binding: binding)], for: target, pluginID: "second")
    #expect(await registry.context(pluginID: "network-logger", target: target)?.operations.first?.available == false)
    await registry.setDeviceProviders([], for: target, pluginID: "second")
    #expect(await registry.context(pluginID: "network-logger", target: target)?.operations.first?.available == true)
}

@Test func duplicateDeviceContractsWithinOneCatalogAreUnavailable() async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    let binding = makeBinding(name: deviceName)
    try await registry.install(manifest: makeManifest(binding: binding), sourceIdentity: "builtin")
    let provider = StubProvider(binding: binding)
    await registry.setDeviceProviders([provider, provider], for: target, pluginID: "duplicate")
    #expect(await registry.context(pluginID: "network-logger", target: target)?.operations.first?.available == false)
    await registry.setDeviceProviders([provider], for: target, pluginID: "other")
    #expect(await registry.context(pluginID: "network-logger", target: target)?.operations.first?.available == false)
}

@Test func stalePanelCannotUseReplacementInstallationsPrincipal() async throws {
    let registry = makeRegistry()
    let old = NectoPluginPrincipal(pluginID: "network-logger", sourceIdentity: "local:first")
    let current = NectoPluginPrincipal(pluginID: old.pluginID, sourceIdentity: "local:second")
    try await registry.install(manifest: makeManifest(), sourceIdentity: current.sourceIdentity)
    await registry.registerHostProvider(StubProvider())
    #expect(await registry.context(pluginID: old.pluginID, target: nil, expectedPrincipal: old) == nil)
    let error = await #expect(throws: NectoBridgeError.self) {
        try await registry.invoke(pluginID: old.pluginID, operationID: "records.list", target: nil, expectedPrincipal: old)
    }
    #expect(error?.code == .permissionDenied)
    #expect(try await registry.invoke(pluginID: current.pluginID, operationID: "records.list", target: nil, expectedPrincipal: current) == ["ok": true])
}

@Test func invokesHostProvider() async throws {
    let registry = makeRegistry()
    try await registry.install(
        manifest: makeManifest(),
        sourceIdentity: "builtin"
    )
    await registry.registerHostProvider(StubProvider())

    let output = try await registry.invoke(
        pluginID: "network-logger",
        operationID: "records.list",
        target: nil
    )

    #expect(output == ["ok": true])
}

@Test func scopedCatalogDoesNotMergeDesktopAndDevicePlugins() async throws {
    let registry = makeRegistry()
    try await registry.install(manifest: makeManifest(), sourceIdentity: "builtin")

    #expect(await registry.installedPlugins(for: nil).map(\.manifest.id) == ["network-logger"])

    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    try await registry.installDevice(
        manifest: makeManifest(pluginID: "device-variables", binding: makeBinding(name: deviceName)),
        sourceIdentity: "device:com.example.app",
        for: target
    )
    #expect(await registry.installedPlugins(for: target).map(\.manifest.id) == ["device-variables"])
    #expect(await registry.installedPlugins(for: nil).map(\.manifest.id) == ["network-logger"])
    #expect(await registry.installedPlugins(for: NectoTarget(deviceID: "other", appBundleID: "com.example.app")).isEmpty)
}

/// There is no permission name between a plugin and a bridge, so a manifest that binds
/// to something nobody answers is refused for that reason rather than a borrowed one.
@Test func saysWhenNothingProvidesTheBridge() async throws {
    let registry = makeRegistry()
    try await registry.install(manifest: makeManifest(), sourceIdentity: "builtin")

    let context = await registry.context(pluginID: "network-logger", target: nil)
    let operation = try #require(context?.operations.first)
    #expect(!operation.available)
    #expect(operation.unavailableReason?.contains("No provider") == true)
}

@Test func deviceNeedsSelectedTarget() async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    try await registry.install(
        manifest: makeManifest(binding: makeBinding(name: deviceName)),
        sourceIdentity: "builtin"
    )
    await registry.setDeviceProviders([StubProvider(binding: makeBinding(name: deviceName))], for: target, pluginID: "app-plugin")

    let withoutTarget = await registry.context(pluginID: "network-logger", target: nil)
    #expect(withoutTarget?.operations.first?.available == false)

    let withTarget = await registry.context(pluginID: "network-logger", target: target)
    #expect(withTarget?.operations.first?.available == true)
    #expect(withTarget?.target?.targetHandle.isEmpty == false)
    let info = try #require(withTarget?.target)
    let json = try JSONEncoder().encode(info)
    let encoded = try #require(JSONSerialization.jsonObject(with: json) as? [String: String])
    #expect(encoded["deviceID"] == encoded["targetHandle"])
    #expect(!encoded.values.contains(target.deviceID))

    let output = try await registry.invoke(
        pluginID: "network-logger",
        operationID: "records.list",
        target: target
    )
    #expect(output == ["ok": true])
}

@Test func dropsAppProvidersWhenTargetDisconnects() async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    try await registry.install(
        manifest: makeManifest(binding: makeBinding(name: deviceName)),
        sourceIdentity: "builtin"
    )
    await registry.setDeviceProviders([StubProvider(binding: makeBinding(name: deviceName))], for: target, pluginID: "app-plugin")
    await registry.unregisterDeviceProviders(for: target)

    let context = await registry.context(pluginID: "network-logger", target: target)
    #expect(context?.operations.first?.available == false)
    #expect(context?.operations.first?.unavailableReason?.contains("does not provide") == true)
}

@Test func rejectsInputThatFailsSchema() async throws {
    let registry = makeRegistry()
    try await registry.install(
        manifest: makeManifest(inputSchema: [
            "type": "object",
            "required": ["limit"],
            "properties": ["limit": ["type": "integer"]],
        ]),
        sourceIdentity: "builtin"
    )
    await registry.registerHostProvider(StubProvider())

    let error = await #expect(throws: NectoBridgeError.self) {
        try await registry.invoke(
            pluginID: "network-logger",
            operationID: "records.list",
            input: ["limit": "50"],
            target: nil
        )
    }
    #expect(error?.code == .invalidInput)
}

@Test func rejectsProviderOutputThatFailsSchema() async throws {
    let registry = makeRegistry()
    try await registry.install(
        manifest: makeManifest(outputSchema: [
            "type": "object",
            "required": ["records"],
        ]),
        sourceIdentity: "builtin"
    )
    await registry.registerHostProvider(StubProvider())

    let error = await #expect(throws: NectoBridgeError.self) {
        try await registry.invoke(
            pluginID: "network-logger",
            operationID: "records.list",
            target: nil
        )
    }
    #expect(error?.code == .invalidOutput)
}


@Test func rejectsProviderWhoseContractDisagreesWithManifest() async throws {
    let registry = makeRegistry()
    try await registry.install(
        manifest: makeManifest(),
        sourceIdentity: "builtin"
    )
    // The manifest says it answers once while the provider claims to keep answering.
    await registry.registerHostProvider(StubProvider(kind: .stream))

    let context = await registry.context(pluginID: "network-logger", target: nil)
    let reason = context?.operations.first?.unavailableReason
    #expect(reason?.contains("is a stream") == true)
    #expect(reason?.contains("declares a once") == true)
}

@Test func issuesStableTargetHandlePerPlugin() async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    try await registry.install(
        manifest: makeManifest(),
        sourceIdentity: "builtin"
    )

    let first = await registry.context(pluginID: "network-logger", target: target)?.target?.targetHandle
    let second = await registry.context(pluginID: "network-logger", target: target)?.target?.targetHandle

    #expect(first != nil)
    #expect(first == second)
    #expect(first != target.deviceID)
}

// MARK: A plugin coming and going while the app runs

/// An app registers by declaring a plugin's whole catalog, so a plugin the app removed
/// arrives as an empty one. Removal needs no message of its own.
@Test func anEmptyCatalogTakesThePluginAway() async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    let binding = makeBinding(name: deviceName)
    try await registry.install(
        manifest: makeManifest(binding: binding),
        sourceIdentity: "builtin"
    )

    await registry.setDeviceProviders([StubProvider(binding: binding)], for: target, pluginID: "app-plugin")
    #expect(await registry.context(pluginID: "network-logger", target: target)?.operations.first?.available == true)

    await registry.setDeviceProviders([], for: target, pluginID: "app-plugin")
    #expect(await registry.context(pluginID: "network-logger", target: target)?.operations.first?.available == false)
}

/// Registering again replaces rather than adds, so a plugin that dropped one of its
/// operations really loses it.
@Test func registeringAgainReplacesTheCatalog() async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    let binding = makeBinding(name: deviceName)
    try await registry.install(
        manifest: makeManifest(binding: binding),
        sourceIdentity: "builtin"
    )

    await registry.setDeviceProviders([StubProvider(binding: binding)], for: target, pluginID: "app-plugin")
    await registry.setDeviceProviders(
        [StubProvider(binding: makeBinding(name: "app.other"))],
        for: target,
        pluginID: "app-plugin"
    )

    #expect(await registry.context(pluginID: "network-logger", target: target)?.operations.first?.available == false)
}

/// One plugin leaving must not take another's contracts with it.
@Test func removingOnePluginLeavesTheOthers() async throws {
    let registry = makeRegistry()
    let target = NectoTarget(deviceID: "device-1", appBundleID: "com.example.app")
    let binding = makeBinding(name: deviceName)
    try await registry.install(
        manifest: makeManifest(binding: binding),
        sourceIdentity: "builtin"
    )

    await registry.setDeviceProviders([StubProvider(binding: binding)], for: target, pluginID: "keeper")
    await registry.setDeviceProviders(
        [StubProvider(binding: makeBinding(name: "app.other"))],
        for: target,
        pluginID: "leaver"
    )
    await registry.setDeviceProviders([], for: target, pluginID: "leaver")

    #expect(await registry.context(pluginID: "network-logger", target: target)?.operations.first?.available == true)
}

/// Nothing is asked at call time. Someone read the bridge names when the plugin was
/// installed and said yes, and a second question about the same thing is a question
/// people learn to click through.
@Test func aWriteRunsWithoutBeingAskedAgain() async throws {
    let registry = makeRegistry()
    let binding = makeBinding(name: "necto.desktop.records.clear")
    try await registry.install(manifest: makeManifest(binding: binding), sourceIdentity: "builtin")
    await registry.registerHostProvider(StubProvider(binding: binding))

    let output = try await registry.invoke(
        pluginID: "network-logger",
        operationID: "records.list",
        target: nil
    )
    #expect(output == ["ok": true])
}
