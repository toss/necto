//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoMacService

@Suite("File save bridge")
struct NectoFileSaveProviderTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "necto-save-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func context() -> NectoInvocationContext {
        NectoInvocationContext(
            principal: NectoPluginPrincipal(pluginID: "test", sourceIdentity: "test"),
            target: nil
        )
    }

    @Test("writes the bytes it was given and says where")
    func saves() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = NectoFileSaveProvider(directory: directory)

        let output = try await provider.invoke(
            input: ["name": "shot.png", "base64": .string(Data("hello".utf8).base64EncodedString())],
            context: context()
        )

        let path = try #require(output["path"]?.stringValue)
        #expect(try Data(contentsOf: URL(filePath: path)) == Data("hello".utf8))
    }

    /// A save must never quietly replace what an earlier save produced.
    @Test("a taken name gets a numbered sibling")
    func neverOverwrites() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = NectoFileSaveProvider(directory: directory)
        let input: NectoJSONValue = ["name": "shot.png", "base64": .string(Data("one".utf8).base64EncodedString())]

        let first = try await provider.invoke(input: input, context: context())
        let second = try await provider.invoke(input: input, context: context())

        #expect(first["path"]?.stringValue?.hasSuffix("shot.png") == true)
        #expect(second["path"]?.stringValue?.hasSuffix("shot 2.png") == true)
    }

    /// The name is content, not a path: whatever it says, the file stays in the folder.
    @Test("a name cannot climb out of the folder")
    func sanitisesNames() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = NectoFileSaveProvider(directory: directory)

        let output = try await provider.invoke(
            input: ["name": "../../escape.png", "base64": .string(Data("x".utf8).base64EncodedString())],
            context: context()
        )

        let path = try #require(output["path"]?.stringValue)
        #expect(URL(filePath: path).deletingLastPathComponent().path == directory.path)
    }

    @Test("refuses what does not decode")
    func refusesBadBase64() async {
        let provider = NectoFileSaveProvider(directory: FileManager.default.temporaryDirectory)
        await #expect(throws: NectoBridgeError.self) {
            try await provider.invoke(input: ["name": "x.png", "base64": "not base64!!"], context: context())
        }
    }
}
