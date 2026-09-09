//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// Writes something a plugin produced onto the Mac.
///
/// A screenshot taken on the device is worth nothing trapped in a panel, so this is
/// the way out: bytes in, a file in Downloads, the path back. It only ever creates —
/// a name that exists gets a numbered sibling, because a save must never quietly
/// replace what an earlier save produced.
public struct NectoFileSaveProvider: NectoOperationProvider {
    public static let key = "necto.desktop.files.save"

    public let descriptor = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: key, version: 1),
        kind: .once,
        inputSchema: [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "base64": ["type": "string"],
            ],
            "required": ["name", "base64"],
            "additionalProperties": false,
        ],
        outputSchema: [
            "type": "object",
            "properties": ["path": ["type": "string"]],
            "required": ["path"],
            "additionalProperties": true,
        ]
    )

    private let directory: URL

    /// Downloads by default: the one folder every Mac user already checks.
    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public func invoke(input: NectoJSONValue, context _: NectoInvocationContext) async throws -> NectoJSONValue {
        guard let rawName = input["name"]?.stringValue, !rawName.isEmpty else {
            throw NectoBridgeError(code: .invalidInput, message: "name is required")
        }
        guard let base64 = input["base64"]?.stringValue,
              let data = Data(base64Encoded: base64) else {
            throw NectoBridgeError(code: .invalidInput, message: "base64 did not decode")
        }

        // The name is content, not a path: whatever it says, it stays in the folder.
        let name = rawName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "")
        guard name != ".", name != ".." else {
            throw NectoBridgeError(code: .invalidInput, message: "'\(rawName)' is not a file name")
        }

        let destination = Self.unusedURL(for: name, in: directory)
        do {
            try data.write(to: destination, options: .withoutOverwriting)
        } catch {
            throw NectoBridgeError(code: .providerFailed, message: "Could not save: \(error.localizedDescription)")
        }
        return ["path": .string(destination.path)]
    }

    /// `name.png`, then `name 2.png`, and so on until a free one.
    static func unusedURL(for name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let extensionPart = (name as NSString).pathExtension

        func candidate(_ counter: Int) -> URL {
            let stem = counter == 1 ? base : "\(base) \(counter)"
            let full = extensionPart.isEmpty ? stem : "\(stem).\(extensionPart)"
            return directory.appending(path: full)
        }

        var counter = 1
        while FileManager.default.fileExists(atPath: candidate(counter).path) {
            counter += 1
        }
        return candidate(counter)
    }
}
