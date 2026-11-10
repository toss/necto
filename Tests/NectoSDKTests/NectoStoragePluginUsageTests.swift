//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoFilesPlugin
import NectoModel
import NectoPreferencesPlugin
import Testing

@Suite("Storage plugin usage")
struct NectoStoragePluginUsageTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "necto-storage-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test("records successful file operations with only the preview format as extra metadata")
    func fileSuccesses() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = PluginUsageRecorder()
        let registrar = recorder.register(NectoFilesPlugin(roots: [
            .init(id: "example-root", name: "Example root", url: root),
        ]))
        let roots = try await recorder.call(registrar, "files.roots")
        #expect(roots["roots"]?.arrayValue?.first?["path"] == .string(root.path))

        let written = try await recorder.call(registrar, "files.write", input: [
            "root": "example-root", "path": "notes.txt", "content": "example text",
        ])
        #expect(written == ["written": true, "size": 12])
        let textURL = root.appending(path: "notes.txt")
        #expect(try String(contentsOf: textURL, encoding: .utf8) == "example text")

        let entries = try await recorder.call(registrar, "files.list", input: ["root": "example-root"])
        #expect(entries["entries"]?.arrayValue?.map { $0["name"] } == [.string("notes.txt")])
        let textInput: NectoJSONValue = ["root": "example-root", "path": "notes.txt"]
        let info = try await recorder.call(registrar, "files.info", input: textInput)
        #expect(info["item"]?["size"] == .number(12))
        let text = try await recorder.call(registrar, "files.preview", input: textInput)
        #expect(text["file"]?["kind"] == .string("text"))
        #expect(text["file"]?["text"] == .string("example text"))

        let image = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        ))
        try image.write(to: root.appending(path: "pixel.png"))
        let imagePreview = try await recorder.call(registrar, "files.preview", input: [
            "root": "example-root", "path": "pixel.png",
        ])
        #expect(imagePreview["file"]?["kind"] == .string("image"))
        #expect(imagePreview["file"]?["base64"] == .string(image.base64EncodedString()))

        try Data([0xFF, 0xFE]).write(to: root.appending(path: "sample.bin"))
        let binary = try await recorder.call(registrar, "files.preview", input: [
            "root": "example-root", "path": "sample.bin",
        ])
        #expect(binary["file"]?["kind"] == .string("binary"))
        #expect(binary["file"]?["base64"] == nil)

        let removed = try await recorder.call(registrar, "files.delete", input: textInput)
        #expect(removed == ["removed": true])
        #expect(!FileManager.default.fileExists(atPath: textURL.path))
        #expect(recorder.events == [
            .init(name: "files.operation", params: ["operation": "write", "result": "success"]),
            .init(name: "files.operation", params: ["operation": "list", "result": "success"]),
            .init(name: "files.operation", params: ["operation": "preview", "result": "success", "format": "text"]),
            .init(name: "files.operation", params: ["operation": "preview", "result": "success", "format": "image"]),
            .init(name: "files.operation", params: ["operation": "preview", "result": "success", "format": "binary"]),
            .init(name: "files.operation", params: ["operation": "delete", "result": "success"]),
        ])
    }

    @Test("records failed file operations without paths or error details")
    func fileFailures() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "example-dir"), withIntermediateDirectories: false)
        let recorder = PluginUsageRecorder()
        let registrar = recorder.register(NectoFilesPlugin(roots: [
            .init(id: "example-root", name: "Example root", url: root),
        ]))
        let missing: NectoJSONValue = ["root": "example-root", "path": "missing.txt"]

        let listError = await #expect(throws: CocoaError.self) {
            try await recorder.call(registrar, "files.list", input: missing)
        }
        #expect(listError?.code == .fileReadNoSuchFile)
        await #expect(throws: NectoBridgeError(code: .invalidInput, message: "'example-dir' is a directory")) {
            try await recorder.call(registrar, "files.preview", input: ["root": "example-root", "path": "example-dir"])
        }
        await #expect(throws: NectoBridgeError(code: .invalidInput, message: "content is required")) {
            try await recorder.call(registrar, "files.write", input: missing)
        }
        let deleteError = await #expect(throws: CocoaError.self) {
            try await recorder.call(registrar, "files.delete", input: missing)
        }
        #expect(deleteError?.code == .fileNoSuchFile)
        #expect(recorder.events == [
            .init(name: "files.operation", params: ["operation": "list", "result": "failure"]),
            .init(name: "files.operation", params: ["operation": "preview", "result": "failure"]),
            .init(name: "files.operation", params: ["operation": "write", "result": "failure"]),
            .init(name: "files.operation", params: ["operation": "delete", "result": "failure"]),
        ])
    }

    @Test("records successful preference operations with the stored value type")
    func preferenceSuccesses() async throws {
        let suite = "necto.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = PluginUsageRecorder()
        let registrar = recorder.register(NectoPreferencesPlugin(suites: [suite]))
        let suites = try await recorder.call(registrar, "preferences.suites")
        #expect(suites == ["suites": ["standard", .string(suite)]])

        let string = try await recorder.call(registrar, "preferences.set", input: [
            "suite": .string(suite), "key": "example.setting", "value": "example value", "type": "example.type",
        ])
        #expect(string["entry"] == ["key": "example.setting", "type": "String", "value": "example value"])
        let integer = try await recorder.call(registrar, "preferences.set", input: [
            "suite": .string(suite), "key": "example.count", "value": 47, "type": "Int",
        ])
        #expect(integer["entry"] == ["key": "example.count", "type": "Int", "value": "47"])
        #expect(defaults.integer(forKey: "example.count") == 47)

        let list = try await recorder.call(registrar, "preferences.list", input: [
            "suite": .string(suite), "prefix": "example.",
        ])
        #expect(list["entries"]?.arrayValue?.map { $0["key"] } == [.string("example.count"), .string("example.setting")])
        let input: NectoJSONValue = ["suite": .string(suite), "key": "example.setting"]
        let detail = try await recorder.call(registrar, "preferences.detail", input: input)
        #expect(detail == string)
        let removed = try await recorder.call(registrar, "preferences.remove", input: input)
        #expect(removed == ["removed": true])
        #expect(defaults.object(forKey: "example.setting") == nil)
        #expect(recorder.events == [
            .init(name: "preferences.operation", params: ["operation": "set", "result": "success", "valueType": "String"]),
            .init(name: "preferences.operation", params: ["operation": "set", "result": "success", "valueType": "Int"]),
            .init(name: "preferences.operation", params: ["operation": "list", "result": "success"]),
            .init(name: "preferences.operation", params: ["operation": "detail", "result": "success"]),
            .init(name: "preferences.operation", params: ["operation": "remove", "result": "success"]),
        ])
    }

    @Test("records failed preference operations without suites, keys or error details")
    func preferenceFailures() async throws {
        let suite = "necto.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("original", forKey: "example.date")
        let recorder = PluginUsageRecorder()
        let registrar = recorder.register(NectoPreferencesPlugin(suites: [suite]))

        let unknownSuite = NectoBridgeError(code: .invalidInput, message: "This app does not offer the suite 'unknown.suite'")
        await #expect(throws: unknownSuite) {
            try await recorder.call(registrar, "preferences.list", input: ["suite": "unknown.suite", "prefix": "example."])
        }
        await #expect(throws: NectoBridgeError(code: .operationUnavailable, message: "No key 'example.missing'")) {
            try await recorder.call(registrar, "preferences.detail", input: [
                "suite": .string(suite), "key": "example.missing",
            ])
        }
        await #expect(throws: NectoBridgeError(code: .invalidInput, message: "'example date' is not an ISO 8601 date")) {
            try await recorder.call(registrar, "preferences.set", input: [
                "suite": .string(suite), "key": "example.date", "value": "example date", "type": "Date",
            ])
        }
        await #expect(throws: unknownSuite) {
            try await recorder.call(registrar, "preferences.remove", input: ["suite": "unknown.suite", "key": "example.date"])
        }
        #expect(defaults.string(forKey: "example.date") == "original")
        #expect(recorder.events == [
            .init(name: "preferences.operation", params: ["operation": "list", "result": "failure"]),
            .init(name: "preferences.operation", params: ["operation": "detail", "result": "failure"]),
            .init(name: "preferences.operation", params: ["operation": "set", "result": "failure"]),
            .init(name: "preferences.operation", params: ["operation": "remove", "result": "failure"]),
        ])
    }
}
