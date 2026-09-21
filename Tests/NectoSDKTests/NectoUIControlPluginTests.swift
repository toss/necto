//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing
@testable import NectoDefaultPlugins
@testable import NectoSDK

private func call(_ plugin: NectoUIControlPlugin, _ name: String, _ input: NectoJSONValue = [:]) async throws -> NectoJSONValue {
    let collector = NectoHandler()
    plugin.register(collector)
    guard case let .once(body)? = collector.registrations["necto.device.control.\(name)@1"]?.body else {
        throw NectoBridgeError(code: .operationUnavailable, message: name)
    }
    return try await body(input)
}

@Suite("Control plugin")
struct NectoUIControlPluginTests {
    private func plugin(_ elements: [NectoControlTarget]) -> NectoUIControlPlugin {
        NectoUIControlPlugin(actionTargets: { elements }, readAccessibility: { [] }) { _, _ in [:] }
    }

    @Test("lists all actionable elements without a count limit or inspector metadata")
    func actionableElements() async throws {
        var elements = (0..<100).map {
            NectoControlTarget(id: "button-\($0)", role: "button", label: "Item \($0)",
                                frame: (0, 0, 100, 40), actions: ["tap"])
        }
        elements.append(NectoControlTarget(id: "label", role: "text", frame: (0, 0, 100, 40), actions: []))
        let output = try await call(plugin(elements), "actionTargets")
        #expect(output["targets"]?.arrayValue?.count == 100)
        let first = try #require(output["targets"]?.arrayValue?.first)
        #expect(first["id"] == "button-0")
        #expect(first["actions"] == ["tap"])
        #expect(first["children"] == nil)
        #expect(first["className"] == nil)
    }

    @Test("searches label, identifier, and role without leaking secure values")
    func searchAndSecureValues() async throws {
        let control = plugin([
            NectoControlTarget(id: "query", role: "textInput", label: "Search", identifier: "search.query",
                                frame: (0, 0, 100, 40), actions: ["tap"], value: "Necto"),
            NectoControlTarget(id: "password", role: "textInput", label: "Password", identifier: "account.password",
                                frame: (0, 50, 100, 40), actions: ["tap"], value: "secret", isSecure: true),
        ])
        for query in [" SEARCH ", "search.query"] {
            let output = try await call(control, "actionTargets", ["query": .string(query)])
            #expect(output["targets"]?.arrayValue?.count == 1)
            #expect(output["targets"]?.arrayValue?.first?["value"] == "Necto")
        }
        let output = try await call(control, "actionTargets", ["query": "textInput"])
        #expect(output["targets"]?.arrayValue?.count == 2)
        #expect(output["targets"]?.arrayValue?.last?["isSecure"] == true)
        #expect(output["targets"]?.arrayValue?.last?["value"] == nil)
        let serialized = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        #expect(!serialized.contains("secret"))
    }

    @Test("non-finite layout values do not break JSON replies")
    func finiteFrame() async throws {
        let control = plugin([NectoControlTarget(id: "moving", role: "button",
            frame: (.nan, 0, .infinity, 40), actions: ["tap"])])
        let output = try await call(control, "actionTargets")
        #expect(output["targets"]?.arrayValue?.first?["frame"] == [0, 0, 0, 40])
        #expect(!(try JSONEncoder().encode(output)).isEmpty)
    }

    @Test("exposes native multi-tap suggestions without changing ordinary targets")
    func tapGestures() async throws {
        let result = try await call(plugin([
            NectoControlTarget(id: "gesture", role: "button", frame: (0, 0, 100, 40), actions: ["tap"],
                tapGestures: [.init(touchCount: 2, tapCount: 3)]),
            NectoControlTarget(id: "ordinary", role: "button", frame: (0, 40, 100, 40), actions: ["tap"]),
        ]), "actionTargets")
        #expect(result["targets"]?.arrayValue?.first?["tapGestures"] == [["touchCount": 2, "tapCount": 3]])
        #expect(result["targets"]?.arrayValue?.last?["tapGestures"] == nil)
    }

    @Test("an empty screen returns an empty list")
    func emptyScreen() async throws {
        let output = try await call(plugin([]), "actionTargets")
        #expect(output["targets"] == [])
    }

    @Test("accessibility reading includes non-actionable content without executable or tree IDs")
    func readsContentSeparately() async throws {
        let control = NectoUIControlPlugin(actionTargets: {
            Issue.record("Reading must not query or invalidate action targets")
            return []
        }, readAccessibility: {
            [NectoAccessibilityItem(role: "heading", label: "Control Detail"),
             NectoAccessibilityItem(role: "text", label: "Read-only label", identifier: "readonly"),
             NectoAccessibilityItem(role: "textInput", label: "Query", value: "테스트"),
             NectoAccessibilityItem(role: "textInput", label: "Password", value: "secret", isSecure: true)]
        }) { _, _ in
            Issue.record("Reading must not execute actions")
            return [:]
        }
        let result = try await call(control, "readAccessibility")
        let items = try #require(result["items"]?.arrayValue)
        #expect(items.count == 4)
        for item in items {
            for key in ["id", "targetID", "nodeID", "actions", "frame", "children"] {
                #expect(item[key] == nil)
            }
        }
        #expect(items.last?["isSecure"] == true)
        #expect(items.last?["value"] == nil)
        for query in [" DETAIL ", "readonly", "테스트"] {
            let filtered = try await call(control, "readAccessibility", ["query": .string(query)])
            #expect(filtered["items"]?.arrayValue?.count == 1)
        }
        let secret = try await call(control, "readAccessibility", ["query": "secret"])
        #expect(secret["items"] == [])
        let serialized = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!serialized.contains("secret"))
    }

    @Test("the bundled panel decodes and validates as a host manifest")
    func bundledManifest() throws {
        let panel = try #require(plugin([]).panel)
        let manifest = try JSONDecoder().decode(NectoPluginManifest.self,
            from: Data(contentsOf: panel.root.appendingPathComponent("manifest.json")))
        try manifest.validate()
        #expect(manifest.id == "control")
        #expect(manifest.name == "Control")
    }

    @Test("only the control contract is registered")
    func contract() {
        let collector = NectoHandler()
        plugin([]).register(collector)
        #expect(Set(collector.registrations.keys) == [
            "necto.device.control.actionTargets@1", "necto.device.control.readAccessibility@1", "necto.device.control.tap@1",
            "necto.device.control.swipe@1", "necto.device.control.back@1", "necto.device.control.input@1",
        ])
    }

    @Test("input requests reach the implementation unchanged", arguments: ["tap", "swipe", "back", "input"])
    func forwardsInputs(operation: String) async throws {
        actor Recorder {
            var received: NectoJSONValue?
            func record(_ input: NectoJSONValue) { received = input }
        }
        let recorder = Recorder()
        let control = NectoUIControlPlugin(actionTargets: { [] }, readAccessibility: { [] }) { actualOperation, input in
            #expect(actualOperation == operation)
            await recorder.record(input)
            return ["sent": true]
        }
        let input: NectoJSONValue = operation == "swipe"
            ? ["targetID": "swipe", "direction": "up"]
            : operation == "input" ? ["targetID": "element", "text": "테스트", "mode": "append"]
            : ["targetID": "element"]
        let result = try await call(control, operation, input)
        #expect(await recorder.received == input)
        #expect(result == ["sent": true])
    }
}
