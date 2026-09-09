//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoMacService

private func makeDirectory(_ build: (URL) throws -> Void) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "necto-layout-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try build(root)
    return root
}

private func plugin(_ name: String, in root: URL) throws {
    let directory = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: directory.appending(path: "manifest.json"))
}

@Test func findsAPluginWhereItIs() throws {
    let root = try makeDirectory { root in
        try Data("{}".utf8).write(to: root.appending(path: "manifest.json"))
    }
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(NectoPluginArchiveLayout.roots(in: root) == [root])
}

/// A release archive wraps everything in one folder. Refusing that would teach people
/// to repack what GitHub handed them.
@Test func findsAPluginOneLevelDown() throws {
    let root = try makeDirectory { try plugin("my-plugin", in: $0) }
    defer { try? FileManager.default.removeItem(at: root) }

    let found = NectoPluginArchiveLayout.roots(in: root)
    #expect(found.count == 1)
    #expect(found.first?.lastPathComponent == "my-plugin")
}

/// Finder adds this to every zip it makes, and it is not a plugin.
@Test func ignoresWhatFinderAddsToAZip() throws {
    let root = try makeDirectory { root in
        try plugin("my-plugin", in: root)
        try plugin("__MACOSX", in: root)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let found = NectoPluginArchiveLayout.roots(in: root)
    #expect(found.count == 1)
    #expect(found.first?.lastPathComponent == "my-plugin")
}

/// A file names no source, so nothing can tell which of several plugins someone meant
/// to trust. Reporting both is what lets the installer refuse instead of choosing.
@Test func reportsEveryPluginInABundleRatherThanPickingOne() throws {
    let root = try makeDirectory { root in
        try plugin("second", in: root)
        try plugin("first", in: root)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(NectoPluginArchiveLayout.roots(in: root).map(\.lastPathComponent) == ["first", "second"])
}

/// Someone who zipped the folder their plugin folder is in made an archive nobody
/// would call wrong, and following a lone folder costs one directory read.
@Test func followsALoneWrapperToWhatItWraps() throws {
    let root = try makeDirectory { root in
        let wrapper = root.appending(path: "wrapper", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try plugin("buried", in: wrapper)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let found = NectoPluginArchiveLayout.roots(in: root)
    #expect(found.count == 1)
    #expect(found.first?.lastPathComponent == "buried")
}

@Test func findsNothingInAFolderThatHoldsNoPlugin() throws {
    let root = try makeDirectory { root in
        try Data("hello".utf8).write(to: root.appending(path: "README.md"))
    }
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(NectoPluginArchiveLayout.roots(in: root).isEmpty)
}

/// A release archive wraps everything in one folder, and what it wraps may be several
/// plugins. Reporting "no manifest" would be true of the wrapper and useless about the
/// archive — and it is the refusal that has to name what it found.
@Test func looksInsideAWrapperThatHoldsSeveralPlugins() throws {
    let root = try makeDirectory { root in
        let wrapper = root.appending(path: "my-plugins-1.0.0", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try plugin("second", in: wrapper)
        try plugin("first", in: wrapper)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(NectoPluginArchiveLayout.roots(in: root).map(\.lastPathComponent) == ["first", "second"])
}

/// Following a lone folder must not become following a chain of them: a zip can nest a
/// thousand as cheaply as one.
@Test func stopsFollowingWrappersLongBeforeAnArchiveCanExhaustIt() throws {
    let root = try makeDirectory { root in
        var deep = root
        for level in 0 ..< 6 {
            deep = deep.appending(path: "level-\(level)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        }
        try plugin("buried", in: deep)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(NectoPluginArchiveLayout.roots(in: root).isEmpty)
}

/// A folder beside another is not a wrapper, so a plugin's own asset folders never look
/// like somewhere to keep searching.
@Test func doesNotFollowAFolderThatSitsBesideAnother() throws {
    let root = try makeDirectory { root in
        for name in ["assets", "images"] {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try plugin("assets/nested", in: root)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(NectoPluginArchiveLayout.roots(in: root).isEmpty)
}

@Test func extractsAZIPUsingTheBoundedProcessRunner() async throws {
    let root = try makeDirectory { try plugin("sample", in: $0) }
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appending(path: "plugin.zip")
    let staging = root.appending(path: "unpacked")
    let output = try await NectoProcessRunner.run("/usr/bin/ditto", arguments: [
        "-c", "-k", "--keepParent", root.appending(path: "sample").path, archive.path
    ])
    #expect(output.exitCode == 0)
    try await NectoPluginArchiveLayout.extractZIP(at: archive, into: staging)
    #expect(NectoPluginArchiveLayout.roots(in: staging).map(\.lastPathComponent) == ["sample"])
    #expect(try String(contentsOf: staging.appending(path: "sample/manifest.json"), encoding: .utf8) == "{}")
}

@Test func rejectsAnInvalidZIPWithoutWaitingForUnreadErrorOutput() async throws {
    let root = try makeDirectory { try Data("not a zip".utf8).write(to: $0.appending(path: "plugin.zip")) }
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: CocoaError.self) {
        try await NectoPluginArchiveLayout.extractZIP(at: root.appending(path: "plugin.zip"),
                                                     into: root.appending(path: "unpacked"))
    }
}

@Test func cancelledExtractionDoesNotStartAProcess() async throws {
    let root = try makeDirectory { _ in }
    defer { try? FileManager.default.removeItem(at: root) }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await NectoPluginArchiveLayout.extractZIP(at: root.appending(path: "missing.zip"),
                                                     into: root.appending(path: "unpacked"))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "unpacked").path))
}
