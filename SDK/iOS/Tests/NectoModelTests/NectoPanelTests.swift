//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoModel

@Suite("Panel archives")
struct NectoPanelArchiveTests {
    private func makeArchive() -> NectoPanelArchive {
        NectoPanelArchive(files: [
            .init(path: "index.html", data: Data("<!doctype html>".utf8)),
            .init(path: "assets/index.js", data: Data("console.log(1)".utf8)),
            .init(path: "manifest.json", data: Data("{}".utf8)),
        ])
    }

    @Test("binary content cannot impersonate file boundaries")
    func hashSeparatesBinaryFileBoundaries() {
        let first = NectoPanelArchive(files: [.init(path: "a", data: Data([88, 0, 98, 0, 89]))])
        let second = NectoPanelArchive(files: [
            .init(path: "a", data: Data([88])), .init(path: "b", data: Data([89])),
        ])
        #expect(first.legacyContentHash == second.legacyContentHash)
        #expect(first.contentHash != second.contentHash)
    }

    @Test("new stamps remain decodable by older hosts")
    func stampCompatibility() throws {
        struct OldStamp: Decodable { let hash: String }
        let archive = makeArchive()
        let old = try JSONDecoder().decode(OldStamp.self, from: JSONEncoder().encode(archive.stamp))
        #expect(old.hash == archive.legacyContentHash)
        let legacy = try JSONDecoder().decode(NectoPanelStamp.self, from: Data(#"{"hash":"legacy"}"#.utf8))
        #expect(legacy.contentHash == nil)
    }

    @Test("renaming, adding and removing files changes the hash")
    func hashSeesFileMembership() {
        let archive = makeArchive()
        var renamed = archive.files
        renamed[0] = .init(path: "renamed.js", data: renamed[0].data)
        #expect(NectoPanelArchive(files: renamed).contentHash != archive.contentHash)
        #expect(NectoPanelArchive(files: Array(archive.files.dropLast())).contentHash != archive.contentHash)
        #expect(NectoPanelArchive(files: archive.files + [.init(path: "empty", data: Data())]).contentHash != archive.contentHash)
    }

    @Test("equivalent paths are rejected before creating the destination", arguments: [
        ["a.js", "a.js"], ["a.js", "A.js"], ["é.js", "e\u{301}.js"], ["a//b.js"], ["a/./b.js"], ["a\0.js"],
        ["a", "a/b.js"], ["A", "a/b/c.js"], ["é", "e\u{301}/b.js"],
    ])
    func equivalentPaths(paths: [String]) {
        let archive = NectoPanelArchive(files: paths.map { .init(path: $0, data: Data()) })
        let directory = FileManager.default.temporaryDirectory.appending(path: "necto-panel-\(UUID().uuidString)")
        #expect(throws: NectoPanelArchiveError.self) { try archive.write(into: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("the hash does not care what order the files were listed in")
    func hashIsCanonical() {
        let forward = makeArchive()
        let backward = NectoPanelArchive(files: forward.files.reversed())
        #expect(forward.contentHash == backward.contentHash)
        #expect(forward == backward)
    }

    @Test("different bytes are a different panel")
    func hashSeesContent() {
        var files = makeArchive().files
        files[0] = .init(path: files[0].path, data: Data("changed".utf8))
        #expect(NectoPanelArchive(files: files).contentHash != makeArchive().contentHash)
    }

    @Test("what is written out reads back as the same archive")
    func roundtripsThroughDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "necto-panel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = makeArchive()
        try archive.write(into: directory)
        #expect(try NectoPanelArchive.read(directory: directory) == archive)
    }

    @Test("writing refuses existing files, directories and symlinks", arguments: ["file", "directory", "symlink", "dangling"])
    func refusesExistingDestination(kind: String) throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: "necto-panel-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appending(path: "panel")
        let outside = base.appending(path: "outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appending(path: "index.html")
        try Data("keep".utf8).write(to: sentinel)
        switch kind {
        case "file": try Data("keep".utf8).write(to: destination)
        case "directory": try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        case "symlink": try manager.createSymbolicLink(at: destination, withDestinationURL: outside)
        default: try manager.createSymbolicLink(at: destination, withDestinationURL: base.appending(path: "missing"))
        }
        #expect(throws: (any Error).self) { try makeArchive().write(into: destination) }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(!manager.fileExists(atPath: outside.appending(path: "assets").path))
        #expect(!manager.fileExists(atPath: base.appending(path: "missing").path))
    }

    @Test("a path that leaves the panel never touches the disk")
    func refusesTraversal() {
        let escaping = NectoPanelArchive(files: [.init(path: "../outside.js", data: Data())])
        let absolute = NectoPanelArchive(files: [.init(path: "/etc/hosts", data: Data())])
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "necto-panel-\(UUID().uuidString)")

        #expect(throws: NectoPanelArchiveError.self) { try escaping.write(into: directory) }
        #expect(throws: NectoPanelArchiveError.self) { try absolute.write(into: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("hidden files are not part of a panel")
    func readSkipsHiddenFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "necto-panel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try makeArchive().write(into: directory)
        try Data("junk".utf8).write(to: directory.appending(path: ".DS_Store"))

        #expect(try NectoPanelArchive.read(directory: directory) == makeArchive())
    }

    @Test("a symlink cannot make panel identity read outside its root")
    func readRefusesEscapingSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "necto-panel-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "necto-outside-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "outside.txt"),
            withDestinationURL: outside
        )

        #expect(throws: NectoPanelArchiveError.self) {
            try NectoPanelArchive.read(directory: root)
        }
    }

    @Test("the wire shape carries every byte")
    func roundtripsThroughJSON() throws {
        let archive = makeArchive()
        #expect(try NectoPanelArchive(jsonValue: archive.jsonValue) == archive)
    }

    @Test("a registration without a panel still decodes")
    func registrationBackCompat() throws {
        let old = Data("""
        {"pluginID": "example", "catalog": {"catalogVersion": 1, "bridges": []}}
        """.utf8)
        let decoded = try JSONDecoder().decode(NectoPluginRegistration.self, from: old)
        #expect(decoded.panel == nil)

        let stamped = NectoPluginRegistration(
            pluginID: "example",
            catalog: NectoBridgeCatalog(bridges: []),
            panel: NectoPanelStamp(hash: "abc")
        )
        let reencoded = try JSONDecoder().decode(
            NectoPluginRegistration.self,
            from: JSONEncoder().encode(stamped)
        )
        #expect(reencoded.panel?.hash == "abc")
    }
}
