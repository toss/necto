//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import CryptoKit
import Foundation

/// What a registration says about the panel it carries: enough to decide whether to
/// fetch it, and nothing more.
///
/// `hash` keeps older hosts compatible. New hosts use `contentHash` for caching.
public struct NectoPanelStamp: Sendable, Hashable, Codable {
    public let hash: String
    public let contentHash: String?

    public init(hash: String, contentHash: String? = nil) {
        self.hash = hash
        self.contentHash = contentHash
    }
}

/// A panel's files, in the one shape they travel: a flat list of relative paths and
/// bytes. The encoded archive must fit within the transport's message-size limit.
public struct NectoPanelArchive: Sendable, Hashable {
    /// The device side of the fetch. Answered by the SDK itself rather than any
    /// plugin, because the panel belongs to the registration, not to the operations.
    public static let fetchBridge = NectoBridgeBinding(name: "necto.device.plugins.assets", version: 1)

    public struct File: Sendable, Hashable {
        public let path: String
        public let data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public let files: [File]

    public init(files: [File]) {
        // Canonical order at construction, so equality, hashing and encoding never
        // depend on how a file system chose to enumerate.
        self.files = files.sorted { $0.path < $1.path }
    }

    /// The identity of these exact bytes at these exact paths.
    public var contentHash: String {
        var digest = SHA256()
        func appendLength(_ length: Int) {
            withUnsafeBytes(of: UInt64(length).bigEndian) { digest.update(bufferPointer: $0) }
        }
        appendLength(files.count)
        for file in files {
            let path = Data(file.path.utf8)
            appendLength(path.count)
            digest.update(data: path)
            appendLength(file.data.count)
            digest.update(data: file.data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compatibility with pre-length-prefixed SDK stamps. Never use for approvals
    /// or cache reuse: arbitrary binary contents make these record boundaries ambiguous.
    public var legacyContentHash: String {
        var digest = SHA256()
        for file in files {
            digest.update(data: Data(file.path.utf8))
            digest.update(data: [0])
            digest.update(data: file.data)
            digest.update(data: [0])
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public var stamp: NectoPanelStamp { NectoPanelStamp(hash: legacyContentHash, contentHash: contentHash) }

    /// Collects every regular file under `directory`. Hidden files stay out — a
    /// `.DS_Store` must never change what a panel is.
    public static func read(directory: URL) throws -> NectoPanelArchive {
        // Symlinks resolved on both sides, or `/var` and `/private/var` would make
        // the base no prefix of its own children.
        let base = directory.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NectoPanelArchiveError.unreadable(directory.path)
        }

        var files: [File] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw NectoPanelArchiveError.unsafePath(url.path)
            }
            guard values.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(base.path + "/") else {
                throw NectoPanelArchiveError.unsafePath(url.path)
            }
            let path = String(resolved.path.dropFirst(base.path.count + 1))
            files.append(File(path: path, data: try Data(contentsOf: resolved)))
        }
        return NectoPanelArchive(files: files)
    }

    /// Writes into a new directory. Refusing existing destinations prevents stale
    /// files and symlinks from changing the snapshot that was approved.
    public func write(into directory: URL) throws {
        var paths = Set<String>()
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.contains("\0"), !components.contains(""),
                  !components.contains("."), !components.contains(".."),
                  paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw NectoPanelArchiveError.unsafePath(file.path)
            }
        }
        for file in files {
            var components = file.path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                guard !paths.contains(components.joined(separator: "/")) else {
                    throw NectoPanelArchiveError.unsafePath(file.path)
                }
            }
        }

        let manager = FileManager.default
        try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Without intermediate creation this fails for existing directories and
        // dangling symlinks as well as regular files.
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        var completed = false
        defer { if !completed { try? manager.removeItem(at: directory) } }
        for file in files {
            let destination = directory.appending(path: file.path)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.data.write(to: destination)
        }
        completed = true
    }

    /// As it travels in a plugin result: `{"files": [{"path": …, "data": base64}]}`.
    public var jsonValue: NectoJSONValue {
        .object(["files": .array(files.map { file in
            .object([
                "path": .string(file.path),
                "data": .string(file.data.base64EncodedString()),
            ])
        })])
    }

    public init(jsonValue: NectoJSONValue) throws {
        guard let rows = jsonValue["files"]?.arrayValue else {
            throw NectoPanelArchiveError.malformed("no files array")
        }
        self.init(files: try rows.map { row in
            guard let path = row["path"]?.stringValue,
                  let base64 = row["data"]?.stringValue,
                  let data = Data(base64Encoded: base64) else {
                throw NectoPanelArchiveError.malformed("a file row is missing path or data")
            }
            return File(path: path, data: data)
        })
    }
}

public enum NectoPanelArchiveError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsafePath(String)
    case malformed(String)

    public var description: String {
        switch self {
        case let .unreadable(path): "Could not enumerate '\(path)'"
        case let .unsafePath(path): "'\(path)' does not stay inside the panel"
        case let .malformed(reason): "The panel archive is malformed: \(reason)"
        }
    }
}
