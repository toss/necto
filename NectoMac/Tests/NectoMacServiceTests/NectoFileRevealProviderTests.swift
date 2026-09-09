//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import Testing

@testable import NectoMacService

/// The Finder call itself is not exercised — it would open a window on whoever runs
/// the suite. What is testable, and what decides whether this is safe, is which paths
/// the provider agrees to point at.
@Suite("File reveal bridge")
struct NectoFileRevealProviderTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "necto-reveal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func context() -> NectoInvocationContext {
        NectoInvocationContext(
            principal: NectoPluginPrincipal(pluginID: "test", sourceIdentity: "test"),
            target: nil
        )
    }

    @Test("accepts a file the save bridge could have written")
    func acceptsASavedFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = directory.appending(path: "shot.png")

        let resolved = try #require(NectoFileRevealProvider.resolve(path: saved.path, in: directory))
        #expect(resolved.lastPathComponent == "shot.png")
    }

    @Test("refuses anything outside the folder", arguments: [
        "/etc/hosts",
        "~/Documents/secret.txt",
    ])
    func refusesOutsidePaths(path: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(NectoFileRevealProvider.resolve(path: path, in: directory) == nil)
    }

    /// The prefix trap: a folder whose path merely starts with the save folder's text
    /// is a different folder, and comparing strings would let it through.
    @Test("refuses a sibling folder that starts with the same text")
    func refusesAPrefixSibling() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = URL(filePath: directory.path + "-old").appending(path: "shot.png")

        #expect(NectoFileRevealProvider.resolve(path: sibling.path, in: directory) == nil)
    }

    @Test("refuses a path that walks out with ..")
    func refusesATraversal() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(NectoFileRevealProvider.resolve(path: directory.appending(path: "../escaped.png").path, in: directory) == nil)
    }

    /// Nested is out too: `save` never creates a subfolder, so a path inside one was
    /// not written by the bridge this pairs with.
    @Test("refuses a file in a subfolder")
    func refusesASubfolder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(NectoFileRevealProvider.resolve(path: directory.appending(path: "inner/shot.png").path, in: directory) == nil)
    }

    @Test("says so when there is no path to reveal")
    func requiresAPath() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = NectoFileRevealProvider(directory: directory)

        await #expect(throws: NectoBridgeError.self) {
            _ = try await provider.invoke(input: [:], context: context())
        }
    }

    @Test("says so when the file has gone")
    func reportsAMissingFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = NectoFileRevealProvider(directory: directory)

        await #expect(throws: NectoBridgeError.self) {
            _ = try await provider.invoke(
                input: ["path": .string(directory.appending(path: "gone.png").path)],
                context: context()
            )
        }
    }
}
