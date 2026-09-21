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

@Suite("Files plugin")
struct NectoFilesPluginTests {
    /// A directory of its own per test, so nothing reads or writes real app data.
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "necto-files-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plugin(at root: URL) -> NectoFilesPlugin {
        NectoFilesPlugin(roots: [NectoFilesPlugin.Root(id: "test", name: "Test", url: root)])
    }

    @Test("lists directories first, then files by name")
    func listsInBrowserOrder() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appending(path: "b.txt"))
        try Data("hello".utf8).write(to: root.appending(path: "a.txt"))
        try FileManager.default.createDirectory(at: root.appending(path: "z-dir"), withIntermediateDirectories: false)

        let output = try await call(plugin(at: root), "files.list", ["root": "test"])
        let names = output["entries"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["z-dir", "a.txt", "b.txt"])
    }

    @Test("a directory row carries a count, a file row a size")
    func rowsCarryTheRightMeta() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("12345".utf8).write(to: root.appending(path: "five.txt"))
        try FileManager.default.createDirectory(at: root.appending(path: "dir"), withIntermediateDirectories: false)
        try Data("x".utf8).write(to: root.appending(path: "dir/inner.txt"))

        let entries = try #require(
            try await call(plugin(at: root), "files.list", ["root": "test"])["entries"]?.arrayValue
        )
        let directory = try #require(entries.first { $0["name"]?.stringValue == "dir" })
        #expect(directory["itemCount"] == .number(1))
        #expect(directory["size"] == nil)

        let file = try #require(entries.first { $0["name"]?.stringValue == "five.txt" })
        #expect(file["size"] == .number(5))
        #expect(file["itemCount"] == nil)
    }

    @Test("previews text as text and refuses to guess at binary")
    func previews() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"total\": 24900}".utf8).write(to: root.appending(path: "receipt.json"))
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: root.appending(path: "blob.bin"))

        let subject = plugin(at: root)
        let text = try await call(subject, "files.preview", ["root": "test", "path": "receipt.json"])
        #expect(text["file"]?["kind"] == .string("text"))
        #expect(text["file"]?["text"]?.stringValue?.contains("24900") == true)

        let binary = try await call(subject, "files.preview", ["root": "test", "path": "blob.bin"])
        #expect(binary["file"]?["kind"] == .string("binary"))
        #expect(binary["file"]?["text"] == nil)
    }

    /// A 1x1 PNG. Real bytes rather than a stub, so the round trip proves the panel
    /// would be handed something a browser can actually draw.
    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    @Test("hands an image over whole instead of calling it binary")
    func previewsImages() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.onePixelPNG.write(to: root.appending(path: "shot.png"))

        let output = try await call(plugin(at: root), "files.preview", ["root": "test", "path": "shot.png"])
        let file = try #require(output["file"])
        #expect(file["kind"] == .string("image"))
        #expect(file["mediaType"] == .string("image/png"))

        let returned = try #require(file["base64"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        #expect(returned == Self.onePixelPNG)
    }

    /// The cap is the whole reason the image path is safe to read whole, so it has to
    /// hold: past it, the file goes back to being described rather than sent.
    @Test("an image past the size cap is described, not sent")
    func refusesOversizedImages() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 0xFF is not valid UTF-8, so the fallback path cannot mistake this for text.
        try Data(repeating: 0xFF, count: NectoFilesPlugin.imageLimit + 1)
            .write(to: root.appending(path: "huge.png"))

        let output = try await call(plugin(at: root), "files.preview", ["root": "test", "path": "huge.png"])
        #expect(output["file"]?["kind"] == .string("binary"))
        #expect(output["file"]?["base64"] == nil)
    }

    @Test("reads the image type off the extension, whatever its case", arguments: [
        ("shot.png", "image/png"),
        ("shot.JPG", "image/jpeg"),
        ("shot.jpeg", "image/jpeg"),
        ("photo.HEIC", "image/heic"),
        ("notes.txt", nil),
        ("archive.zip", nil),
    ] as [(String, String?)])
    func mapsImageExtensions(name: String, expected: String?) {
        #expect(NectoFilesPlugin.imageMediaType(for: URL(filePath: "/tmp/\(name)")) == expected)
    }

    /// A panel that can name any path can read anything the app can, so a path that
    /// escapes its root is refused however it is written.
    @Test("refuses a path that escapes the root", arguments: [
        "../outside.txt", "a/../../outside.txt", "/etc/hosts",
    ])
    func refusesEscape(path: String) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: NectoBridgeError.self) {
            try await call(plugin(at: root), "files.preview", ["root": "test", "path": .string(path)])
        }
    }

    @Test("refuses a root the app never offered")
    func refusesUnknownRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: NectoBridgeError.self) {
            try await call(plugin(at: root), "files.list", ["root": "somewhere-else"])
        }
    }

    @Test("deletes what it is asked to and nothing else survives wrongly")
    func deletes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("bye".utf8).write(to: root.appending(path: "gone.txt"))
        try Data("stay".utf8).write(to: root.appending(path: "kept.txt"))

        let subject = plugin(at: root)
        _ = try await call(subject, "files.delete", ["root": "test", "path": "gone.txt"])

        let names = try await call(subject, "files.list", ["root": "test"])["entries"]?.arrayValue?
            .compactMap { $0["name"]?.stringValue }
        #expect(names == ["kept.txt"])
    }

    @Test("writes UTF-8 text atomically inside an offered root")
    func writes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("before".utf8).write(to: root.appending(path: "note.txt"))

        let output = try await call(plugin(at: root), "files.write", [
            "root": "test",
            "path": "note.txt",
            "content": "after 한글",
        ])

        #expect(output["written"] == .bool(true))
        #expect(try String(contentsOf: root.appending(path: "note.txt"), encoding: .utf8) == "after 한글")
    }

    @Test("reports metadata for files and directories")
    func reportsInfo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("12345".utf8).write(to: root.appending(path: "five.txt"))
        try FileManager.default.createDirectory(at: root.appending(path: "folder"), withIntermediateDirectories: false)

        let subject = plugin(at: root)
        let file = try await call(subject, "files.info", ["root": "test", "path": "five.txt"])
        #expect(file["item"]?["name"] == .string("five.txt"))
        #expect(file["item"]?["isDirectory"] == .bool(false))
        #expect(file["item"]?["size"] == .number(5))

        let directory = try await call(subject, "files.info", ["root": "test", "path": "folder"])
        #expect(directory["item"]?["isDirectory"] == .bool(true))
        #expect(directory["item"]?["itemCount"] == .number(0))
    }

    @Test("says which roots it can open")
    func listsItsRoots() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try await call(plugin(at: root), "files.roots")
        #expect(output["roots"]?.arrayValue?.first?["id"] == .string("test"))
    }
}
