//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoDefaultPlugins
@testable import NectoSDK

/// Runs a plugin's registration the way the runtime does.
private func call(
    _ plugin: any NectoPluginable,
    _ name: String,
    _ input: NectoJSONValue = [:]
) async throws -> NectoJSONValue {
    let collector = NectoHandler()
    plugin.register(collector)
    guard case let .once(body)? = collector.registrations["necto.device.\(name)@1"]?.body else {
        throw NectoBridgeError(code: .operationUnavailable, message: name)
    }
    return try await body(input)
}

@Suite("View inspector plugin")
struct DefaultViewInspectorPluginTests {
    /// A window with a label inside a stack — the smallest tree with every field in it.
    private func makePlugin() -> DefaultViewInspectorPlugin {
        DefaultViewInspectorPlugin {
            [
                NectoViewNode(
                    className: "UIWindow",
                    frame: (0, 0, 393, 852),
                    children: [
                        NectoViewNode(
                            className: "UIStackView",
                            frame: (16, 248, 361, 148),
                            children: [
                                NectoViewNode(
                                    className: "UILabel",
                                    text: "Order total",
                                    frame: (16, 248, 112, 20),
                                    alpha: 0.5
                                ),
                                NectoViewNode(className: "SpinnerView", frame: (16, 300, 44, 44), isHidden: true),
                            ]
                        ),
                    ]
                ),
            ]
        }
    }

    @Test("walks the tree it was handed, nested as it was")
    func walksTheTree() async throws {
        let output = try await call(makePlugin(), "views.tree")

        let window = try #require(output["windows"]?.arrayValue?.first)
        #expect(window["className"] == .string("UIWindow"))
        #expect(window["frame"] == .array([0, 0, 393, 852]))

        let stack = try #require(window["children"]?.arrayValue?.first)
        let label = try #require(stack["children"]?.arrayValue?.first)
        #expect(label["className"] == .string("UILabel"))
        #expect(label["text"] == .string("Order total"))
    }

    /// Most views are visible and opaque, so those fields only travel when they say
    /// something — a tree of thousands should not carry two fields of noise each.
    @Test("omits what goes without saying")
    func omitsDefaults() async throws {
        let output = try await call(makePlugin(), "views.tree")
        let window = try #require(output["windows"]?.arrayValue?.first)
        #expect(window["isHidden"] == nil)
        #expect(window["alpha"] == nil)
        #expect(window["text"] == nil)

        let stack = try #require(window["children"]?.arrayValue?.first)
        let label = try #require(stack["children"]?.arrayValue?.first)
        let spinner = try #require(stack["children"]?.arrayValue?.last)
        #expect(label["alpha"] == .number(0.5))
        #expect(spinner["isHidden"] == .bool(true))
    }

    /// Layout can leave a NaN frame mid-flight, and JSON cannot say NaN: without
    /// sanitising, the reply fails to encode and the panel waits forever.
    @Test("a NaN frame still encodes")
    func nanFrameStillEncodes() async throws {
        let plugin = DefaultViewInspectorPlugin {
            [NectoViewNode(className: "Mid", frame: (Double.nan, 0, .infinity, 20))]
        }
        let output = try await call(plugin, "views.tree")
        let window = try #require(output["windows"]?.arrayValue?.first)
        #expect(window["frame"] == .array([0, 0, 0, 20]))

        // The proof is the encoder itself: the whole reply must survive JSON.
        let data = try JSONEncoder().encode(output)
        #expect(!data.isEmpty)
    }

    @Test("an app with no windows answers an empty forest, not an error")
    func emptyTree() async throws {
        let plugin = DefaultViewInspectorPlugin { [] }
        let output = try await call(plugin, "views.tree")
        #expect(output["windows"]?.arrayValue?.isEmpty == true)
    }

    @Test("searches and inspects stable view identifiers")
    func searchAndInspect() async throws {
        let plugin = DefaultViewInspectorPlugin {
            [NectoViewNode(id: "label", className: "UILabel", text: "Order total", frame: (0, 0, 100, 20))]
        }
        let matches = try await call(plugin, "views.search", ["query": "order"])
        #expect(matches["matches"]?.arrayValue?.first?["id"] == .string("label"))

        let detail = try await call(plugin, "views.inspect", ["viewID": "label"])
        #expect(detail["view"]?["className"] == .string("UILabel"))
    }

    @Test("compares a saved hierarchy with the current one")
    func comparesSnapshots() async throws {
        actor State {
            var text = "Before"
            func read() -> String { text }
            func update() { text = "After" }
        }
        let state = State()
        let plugin = DefaultViewInspectorPlugin {
            [NectoViewNode(id: "label", className: "UILabel", text: await state.read(), frame: (0, 0, 100, 20))]
        }
        let saved = try await call(plugin, "views.snapshot")
        let id = try #require(saved["snapshotID"]?.stringValue)
        await state.update()

        let comparison = try await call(plugin, "views.compare", ["baselineSnapshotID": .string(id)])
        #expect(comparison["changes"]?.arrayValue?.first?["change"] == .string("modified"))
    }

    @Test("declares every inspection and interaction contract")
    func declaresContracts() {
        let collector = NectoHandler()
        makePlugin().register(collector)
        #expect(Set(collector.registrations.keys) == [
            "necto.device.views.tree@1", "necto.device.views.search@1", "necto.device.views.inspect@1",
            "necto.device.views.compare@1", "necto.device.views.snapshot@1", "necto.device.views.highlight@1",
            "necto.device.views.tap@1", "necto.device.views.tapAt@1", "necto.device.views.scroll@1",
            "necto.device.views.swipe@1", "necto.device.views.drag@1", "necto.device.views.longPress@1",
            "necto.device.views.inputText@1",
        ])
    }

    @Test("forwards interaction inputs without giving the SDK feature knowledge")
    func forwardsInteractionInputs() async throws {
        actor Recorder {
            var operation: String?
            var input: NectoJSONValue?
            func record(_ operation: String, _ input: NectoJSONValue) {
                self.operation = operation
                self.input = input
            }
        }
        let recorder = Recorder()
        let plugin = DefaultViewInspectorPlugin(
            snapshot: { [] },
            action: { operation, input in
                await recorder.record(operation, input)
                return ["inserted": true, "length": 5, "method": "UIKeyInput"]
            }
        )

        let input: NectoJSONValue = ["viewID": "field", "text": "hello", "replace": true]
        let output = try await call(plugin, "views.inputText", input)

        #expect(await recorder.operation == "inputText")
        #expect(await recorder.input == input)
        #expect(output["inserted"] == true)
    }
}
