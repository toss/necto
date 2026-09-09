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
private func registrations(of plugin: any NectoPluginable) -> [String: NectoHandler.Registration] {
    let collector = NectoHandler()
    plugin.register(collector)
    return collector.registrations
}

private func answer(
    _ plugin: any NectoPluginable,
    _ key: String,
    _ input: NectoJSONValue = [:]
) async throws -> NectoJSONValue {
    guard case let .once(body)? = registrations(of: plugin)["\(key)@1"]?.body else {
        throw NectoBridgeError(code: .operationUnavailable, message: key)
    }
    return try await body(input)
}

private func makeRecord(id: String = "record-1", url: String = "https://example.com") -> NectoNetworkRecord {
    NectoNetworkRecord(
        id: id,
        method: "GET",
        url: url,
        startedAtMilliseconds: 1000,
        state: .completed,
        statusCode: 200
    )
}

@Test func networkPluginAnswersItsOwnContracts() async throws {
    // The network plugin is an ordinary plugin. It declares contracts and answers
    // them, and nothing on the Mac side knows it exists.
    let plugin = DefaultNetworkPlugin()
    plugin.report(makeRecord(url: "https://example.com/things?page=2"))

    let output = try await answer(plugin, "necto.device.network-records.list", [:])
    let records = try #require(output["records"]?.arrayValue)
    #expect(records.count == 1)
    #expect(records.first?["name"]?.stringValue == "things?page=2")
    #expect(records.first?["host"]?.stringValue == "example.com")
}

/// The list carries no bodies: five hundred rows should not drag five hundred response
/// bodies with them, so they live behind `detail`.
@Test func listOmitsBodiesAndDetailCarriesThem() async throws {
    let plugin = DefaultNetworkPlugin()
    plugin.report(makeRecord())

    let list = try await answer(plugin, "necto.device.network-records.list", [:])
    #expect(list["records"]?.arrayValue?.first?["responseBody"] == nil)

    let detail = try await answer(plugin, "necto.device.network-records.detail", ["recordID": .string("record-1")])
    #expect(detail["record"]?["id"]?.stringValue == "record-1")
}

@Test func detailRefusesAnUnknownRecord() async {
    let plugin = DefaultNetworkPlugin()
    await #expect(throws: NectoBridgeError.self) {
        try await answer(plugin, "necto.device.network-records.detail", ["recordID": .string("nope")])
    }
}

/// The app keeps its own records, so it collects from the moment it starts rather than
/// from the moment someone opens the panel.
@Test func recordsSurviveWithNoHostAttached() async throws {
    let plugin = DefaultNetworkPlugin()
    plugin.report(makeRecord())
    plugin.report(makeRecord(id: "record-2"))

    let output = try await answer(plugin, "necto.device.network-records.list", [:])
    #expect(output["records"]?.arrayValue?.count == 2)
}

@Test func clearEmptiesTheList() async throws {
    let plugin = DefaultNetworkPlugin()
    plugin.report(makeRecord())

    _ = try await answer(plugin, "necto.device.network-records.clear", [:])

    let output = try await answer(plugin, "necto.device.network-records.list", [:])
    #expect(output["records"]?.arrayValue?.isEmpty == true)
}

@Test func networkPluginDeclaresItsFourOperations() {
    let descriptors = registrations(of: DefaultNetworkPlugin()).values.map(\.descriptor)
    let names = descriptors.map(\.binding.name)

    #expect(Set(names) == [
        "necto.device.network-records.list",
        "necto.device.network-records.detail",
        "necto.device.network-records.observe",
        "necto.device.network-records.clear",
    ])
    // Answered by the app, which is what the name says and where the SDK puts it.
    #expect(descriptors.allSatisfy { $0.binding.type == .device })
}

/// Reading and clearing are the same kind of thing to the runtime: both answer once.
/// That a clear destroys something is in its name, not in a flag beside it.
@Test func everythingButObserveAnswersOnce() {
    let registered = registrations(of: DefaultNetworkPlugin())
    #expect(registered["necto.device.network-records.clear@1"]?.descriptor.kind == .once)
    #expect(registered["necto.device.network-records.list@1"]?.descriptor.kind == .once)
    #expect(registered["necto.device.network-records.observe@1"]?.descriptor.kind == .stream)
}

/// The other half of the bridge: a plugin that waits to be asked.
private struct ContractPlugin: NectoPluginable {
    let id = "com.example.stub"

    func register(_ necto: NectoHandler) {
        necto.handle("com.example.variables") { input in
            ["echoed": input["value"] ?? .null]
        }
    }
}

@Test func registeringRejectsAPluginWithTheSameID() {
    let runtime = NectoSDKRuntime()
    #expect(runtime.register(ContractPlugin()))
    #expect(!runtime.register(ContractPlugin()))

    #expect(runtime.plugins.count == 1)
}

@Test func unregisteringAllowsAnExplicitReplacement() {
    let runtime = NectoSDKRuntime()
    let plugin = ContractPlugin()
    #expect(runtime.register(plugin))
    runtime.unregister(id: plugin.id)
    #expect(runtime.register(plugin))
    #expect(runtime.plugins.count == 1)
}

private struct DuplicatePlugin: NectoPluginable {
    let id = "com.example.stub"
    func register(_ necto: NectoHandler) {
        Issue.record("A duplicate plugin must be rejected before its registration runs")
    }
}

@Test func duplicateDoesNotRunItsRegistration() {
    let runtime = NectoSDKRuntime()
    #expect(runtime.register(ContractPlugin()))
    #expect(!runtime.register(DuplicatePlugin()))
    #expect(runtime.plugins.first is ContractPlugin)
}

@Test func unregisteringTakesThePluginAway() {
    let runtime = NectoSDKRuntime()
    let plugin = ContractPlugin()
    runtime.register(plugin)

    runtime.unregister(id: plugin.id)

    #expect(runtime.plugins.isEmpty)
}

private struct RepeatedContractPlugin: NectoPluginable {
    let id: String
    var repeatInsidePlugin = false

    func register(_ necto: NectoHandler) {
        necto.handle("shared.contract") { input in input }
        if repeatInsidePlugin { necto.handle("shared.contract") { input in input } }
    }
}

@Test func duplicateContractsAcrossPluginsAreRejected() {
    let runtime = NectoSDKRuntime()
    #expect(runtime.register(RepeatedContractPlugin(id: "first")))
    #expect(!runtime.register(RepeatedContractPlugin(id: "second")))
    #expect(runtime.plugins.map(\.id) == ["first"])
    runtime.unregister(id: "first")
    #expect(runtime.register(RepeatedContractPlugin(id: "second")))
}

@Test func duplicateContractsWithinOnePluginAreRejected() {
    let runtime = NectoSDKRuntime()
    #expect(!runtime.register(RepeatedContractPlugin(id: "duplicate", repeatInsidePlugin: true)))
    #expect(runtime.plugins.isEmpty)
}

@Test func unregisteringSomethingThatIsNotThereDoesNothing() {
    let runtime = NectoSDKRuntime()
    runtime.register(ContractPlugin())

    runtime.unregister(id: "nobody")

    #expect(runtime.plugins.count == 1)
}

@Test func statusUpdatesYieldTheCurrentStatusAndLaterTransitions() async {
    let runtime = NectoSDKRuntime()
    var updates = runtime.statusUpdates().makeAsyncIterator()

    #expect(await updates.next() == .stopped)

    runtime.status = .listening(port: 9_999)
    #expect(await updates.next() == .listening(port: 9_999))

    runtime.status = .connected(appBundleID: "com.example.app")
    #expect(await updates.next() == .connected(appBundleID: "com.example.app"))
}

@Test func contractsTravelAsAVersionedCatalog() throws {
    // What the app announces has to survive the wire unchanged, since the host refuses
    // a contract whose shape disagrees with the installed manifest.
    let plugin = ContractPlugin()
    let registration = NectoPluginRegistration(
        pluginID: plugin.id,
        catalog: NectoBridgeCatalog(bridges: registrations(of: plugin).values.map(\.descriptor))
    )

    let decoded = try NectoEnvelope(type: .pluginRegister, encoding: registration)
        .decode(NectoPluginRegistration.self)

    #expect(decoded.pluginID == "com.example.stub")
    // The SDK only ever registers app bridges, so it says so in the name rather than
    // leaving it to a field beside it that could disagree.
    #expect(decoded.catalog.bridges.first?.identity == "necto.device.com.example.variables@1")
    #expect(decoded.catalog.bridges.first?.binding.type == .device)
}

@Test func aPluginAnswersOnlyTheNameItDeclared() async throws {
    let plugin = ContractPlugin()

    let echoed = try await answer(plugin, "necto.device.com.example.variables", ["value": "hello"])
    #expect(echoed["echoed"]?.stringValue == "hello")

    // A name nobody registered has no handler at all, so there is nothing to call.
    #expect(registrations(of: plugin)["necto.device.com.example.nothing@1"] == nil)
}
