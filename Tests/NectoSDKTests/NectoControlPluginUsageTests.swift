//
// Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoUIControlPlugin
import Testing
@testable import NectoSDK

@Suite("Control plugin usage")
struct NectoControlPluginUsageTests {
    @Test("actions retain their results while logging only operation and content change",
          arguments: ["tap", "input", "swipe", "back"], [false, true])
    func action(operation: String, changed: Bool) async throws {
        let input: NectoJSONValue = ["target": "private-target", "text": "private-input"]
        let output: NectoJSONValue = ["contentChanged": .bool(changed), "detail": "private-result"]
        let plugin = NectoUIControlPlugin(actionTargets: { [] }, readAccessibility: { [] }) { received, payload in
            #expect(received == operation)
            #expect(payload == input)
            return output
        }
        let usage = PluginUsageRecorder()
        let registrar = usage.register(plugin)

        #expect(try await usage.call(registrar, "control.\(operation)", input: input) == output)
        #expect(usage.events == [.init(name: "control.operation", params: [
            "operation": .string(operation), "result": "success", "contentChanged": .bool(changed),
        ])])
    }

    @Test("failed actions preserve the error without recording the message")
    func failure() async throws {
        let plugin = NectoUIControlPlugin(actionTargets: { [] }, readAccessibility: { [] }) { _, _ in
            throw NectoBridgeError(code: .operationUnavailable, message: "private-target could not accept private-input")
        }
        let usage = PluginUsageRecorder()
        let registrar = usage.register(plugin)
        do {
            _ = try await usage.call(registrar, "control.input", input: ["text": "private-input"])
            Issue.record("Failed action returned a result")
        } catch let error as NectoBridgeError {
            #expect(error.code == .operationUnavailable)
            #expect(error.message == "private-target could not accept private-input")
        }
        #expect(usage.events == [.init(name: "control.operation", params: ["operation": "input", "result": "failure"])])
    }

    @Test("reads omit queries and returned target information")
    func reads() async throws {
        let plugin = NectoUIControlPlugin(actionTargets: {
            [NectoControlTarget(
                id: "private-id", role: "button", label: "private-label",
                frame: (0, 0, 10, 10), actions: ["tap"]
            )]
        }, readAccessibility: { [] }) { _, _ in [:] }
        let usage = PluginUsageRecorder()
        let registrar = usage.register(plugin)
        let targets = try await usage.call(registrar, "control.actionTargets", input: ["query": "private-label"])
        #expect(targets["targets"]?.arrayValue?.first?["id"] == "private-id")
        _ = try await usage.call(registrar, "control.readAccessibility", input: ["query": "private-query"])
        #expect(usage.events == [
            .init(name: "control.operation", params: ["operation": "actionTargets", "result": "success"]),
            .init(name: "control.operation", params: ["operation": "readAccessibility", "result": "success"]),
        ])
    }
}
