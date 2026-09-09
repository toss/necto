//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Shows a saved file in Finder.
///
/// `necto.desktop.files.save` answers with a path, and a path in a status line is not
/// somewhere a person can go — they still have to find the folder themselves. This is
/// the other half: the file the panel just wrote, selected in a Finder window.
///
/// It only ever reveals what `save` could have written. A plugin naming an arbitrary
/// path would be pointing Finder at the whole disk, and revealing is not a capability
/// worth handing out that widely — so a path outside the save directory is refused.
public struct NectoFileRevealProvider: NectoOperationProvider {
    public static let key = "necto.desktop.files.reveal"

    public let descriptor = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: key, version: 1),
        kind: .once,
        inputSchema: [
            "type": "object",
            "properties": ["path": ["type": "string"]],
            "required": ["path"],
            "additionalProperties": false,
        ],
        outputSchema: [
            "type": "object",
            "properties": ["revealed": ["type": "boolean"]],
            "required": ["revealed"],
            "additionalProperties": true,
        ]
    )

    private let directory: URL

    /// Downloads by default, matching `NectoFileSaveProvider`. Registering the two with
    /// different folders would mean revealing something the panel could not have saved.
    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public func invoke(input: NectoJSONValue, context _: NectoInvocationContext) async throws -> NectoJSONValue {
        guard let raw = input["path"]?.stringValue, !raw.isEmpty else {
            throw NectoBridgeError(code: .invalidInput, message: "path is required")
        }
        guard let target = Self.resolve(path: raw, in: directory) else {
            throw NectoBridgeError(
                code: .invalidInput,
                message: "'\(raw)' is not in the folder Necto saves to"
            )
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw NectoBridgeError(code: .providerFailed, message: "'\(raw)' is not there any more")
        }

        #if canImport(AppKit)
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        return ["revealed": .bool(true)]
        #else
        throw NectoBridgeError(code: .operationUnavailable, message: "Revealing needs AppKit")
        #endif
    }

    /// The file inside `directory` this path names, or nil when it names anything else.
    ///
    /// The comparison is between the containing folder and the save folder, not between
    /// path text: `/Downloads-old/shot.png` must not pass for `/Downloads`, and `..`
    /// cannot walk out of one. Symlinks are resolved on the folders — the file itself
    /// may be gone, and asking to reveal something that has been deleted is a case the
    /// caller is told about rather than one that silently widens the check.
    static func resolve(path: String, in directory: URL) -> URL? {
        let target = URL(filePath: path).standardizedFileURL
        guard !target.lastPathComponent.isEmpty else { return nil }

        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard parent == root else { return nil }

        return URL(filePath: parent).appending(path: target.lastPathComponent)
    }
}
