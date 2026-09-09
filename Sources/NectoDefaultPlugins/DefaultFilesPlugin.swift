//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoSDK
import Foundation

/// The app's own container, read from Necto.
///
/// Like Preferences, it needs nothing reported: register it and it answers, because
/// the sandbox is already there.
///
/// ```swift
/// NectoSDK.register(DefaultFilesPlugin())
/// NectoSDK.register(DefaultFilesPlugin(groups: ["group.com.example"]))
/// ```
public final class DefaultFilesPlugin: NectoPluginable, @unchecked Sendable {
    /// Enough of a text file to recognise it by. The point of a preview is to say what
    /// a file is, not to be an editor.
    static let previewLimit = 32 * 1024

    /// An image is read whole or not at all — half a PNG renders as nothing. Well
    /// under the 32 MB frame limit even after base64, and larger than any screenshot
    /// a device produces. Anything bigger is still reported, as a binary file.
    static let imageLimit = 8 * 1024 * 1024

    /// The image types a panel can render, by extension. Nothing here is sniffed from
    /// the bytes: an app that names a file `.png` and writes something else gets a
    /// broken image, which is the truth about the file.
    static let imageMediaTypes = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "heic": "image/heic",
        "heif": "image/heic",
        "bmp": "image/bmp",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "webp": "image/webp",
    ]

    /// One place a panel may look. The set of roots is the whole reach of this plugin:
    /// a path is only ever resolved inside one of them.
    public struct Root: Sendable {
        public let id: String
        public let name: String
        public let url: URL

        public init(id: String, name: String, url: URL) {
            self.id = id
            self.name = name
            self.url = url
        }
    }

    public let id = "files"

    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module, subdirectory: "Panels/files") }

    private let roots: [Root]

    /// The standard sandbox containers, plus any app groups the app names.
    /// A group this plugin was not told about cannot be browsed.
    public convenience init(groups: [String] = []) {
        var roots: [Root] = []
        let manager = FileManager.default

        if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(Root(id: "documents", name: "Documents", url: documents))
        }
        if let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            roots.append(Root(id: "library", name: "Library", url: library))
        }
        roots.append(Root(id: "tmp", name: "tmp", url: manager.temporaryDirectory))

        for group in groups {
            if let url = manager.containerURL(forSecurityApplicationGroupIdentifier: group) {
                roots.append(Root(id: group, name: group, url: url))
            }
        }
        self.init(roots: roots)
    }

    public init(roots: [Root]) {
        self.roots = roots
    }

    public func register(_ necto: NectoHandler) {
        necto.handle("files.roots") { [self] _ in
            ["roots": .array(roots.map { root in
                [
                    "id": .string(root.id),
                    "name": .string(root.name),
                    "path": .string(root.url.path),
                ]
            })]
        }

        necto.handle("files.list") { [self] input in
            let directory = try resolve(input)
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )

            let encoded = entries
                .map(Self.entry)
                .sorted { first, second in
                    // Directories first, then by name: the shape a person expects a
                    // file browser to have.
                    let firstDirectory = first["isDirectory"] == .bool(true)
                    let secondDirectory = second["isDirectory"] == .bool(true)
                    if firstDirectory != secondDirectory { return firstDirectory }
                    return (first["name"]?.stringValue ?? "") < (second["name"]?.stringValue ?? "")
                }
            return ["entries": .array(encoded)]
        }

        necto.handle("files.preview") { [self] input in
            let file = try resolve(input, requirePath: true)
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isDirectory != true else {
                throw NectoBridgeError(code: .invalidInput, message: "'\(file.lastPathComponent)' is a directory")
            }

            var fields: [String: NectoJSONValue] = [
                "name": .string(file.lastPathComponent),
                "size": .number(Double(values.fileSize ?? 0)),
            ]
            if let modified = values.contentModificationDate {
                fields["modifiedAt"] = .number(modified.timeIntervalSince1970 * 1000)
            }

            // An image is the one binary a panel can actually show, and saying
            // "binary" about a screenshot is what made Files look like it could not
            // open one.
            if let mediaType = Self.imageMediaType(for: file), (values.fileSize ?? 0) <= Self.imageLimit {
                fields["kind"] = .string("image")
                fields["mediaType"] = .string(mediaType)
                fields["base64"] = .string(try Data(contentsOf: file).base64EncodedString())
                return ["file": .object(fields)]
            }

            // Read only the head: the point is recognition, and a log file can be huge.
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: Self.previewLimit) ?? Data()

            if let text = String(data: head, encoding: .utf8) {
                fields["kind"] = .string("text")
                fields["text"] = .string(text)
                fields["isTruncated"] = .bool((values.fileSize ?? 0) > head.count)
            } else {
                // Not UTF-8 is as far as this guesses. Rendering base64 would say nothing.
                fields["kind"] = .string("binary")
            }
            return ["file": .object(fields)]
        }

        necto.handle("files.info") { [self] input in
            let target = try resolve(input, requirePath: true)
            return ["item": Self.entry(target)]
        }

        necto.handle("files.write") { [self] input in
            let target = try resolve(input, requirePath: true)
            guard let content = input["content"]?.stringValue else {
                throw NectoBridgeError(code: .invalidInput, message: "content is required")
            }
            if (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                throw NectoBridgeError(code: .invalidInput, message: "'\(target.lastPathComponent)' is a directory")
            }

            let data = Data(content.utf8)
            try data.write(to: target, options: .atomic)
            return [
                "written": .bool(true),
                "size": .number(Double(data.count)),
            ]
        }

        necto.handle("files.delete") { [self] input in
            let target = try resolve(input, requirePath: true)
            try FileManager.default.removeItem(at: target)
            return ["removed": .bool(true)]
        }
    }

    /// The media type a panel can render this file as, or nil when it is not an
    /// image this plugin offers to show.
    static func imageMediaType(for file: URL) -> String? {
        imageMediaTypes[file.pathExtension.lowercased()]
    }

    // MARK: Paths

    /// The root and path from an input, resolved to a URL that is provably inside the
    /// root. A path that escapes — `..`, absolute, a symlink out — is refused, because
    /// a panel that can name any path can read anything the app can.
    private func resolve(_ input: NectoJSONValue, requirePath: Bool = false) throws -> URL {
        guard let rootID = input["root"]?.stringValue,
              let root = roots.first(where: { $0.id == rootID }) else {
            throw NectoBridgeError(code: .invalidInput, message: "This app does not offer that root")
        }

        let path = input["path"]?.stringValue ?? ""
        if requirePath, path.isEmpty {
            throw NectoBridgeError(code: .invalidInput, message: "path is required")
        }
        guard !path.hasPrefix("/") else {
            throw NectoBridgeError(code: .invalidInput, message: "path must be relative to the root")
        }

        let base = root.url.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = base.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") else {
            throw NectoBridgeError(code: .invalidInput, message: "path escapes the root")
        }
        return resolved
    }

    // MARK: Coding

    static func entry(_ url: URL) -> NectoJSONValue {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ])
        let isDirectory = values?.isDirectory == true

        var fields: [String: NectoJSONValue] = [
            "name": .string(url.lastPathComponent),
            "isDirectory": .bool(isDirectory),
        ]
        if isDirectory {
            // Shallow, and only the count: sizing a tree costs a walk of it.
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            fields["itemCount"] = .number(Double(count))
        } else {
            fields["size"] = .number(Double(values?.fileSize ?? 0))
        }
        if let modified = values?.contentModificationDate {
            fields["modifiedAt"] = .number(modified.timeIntervalSince1970 * 1000)
        }
        if let created = values?.creationDate {
            fields["createdAt"] = .number(created.timeIntervalSince1970 * 1000)
        }
        return .object(fields)
    }
}
