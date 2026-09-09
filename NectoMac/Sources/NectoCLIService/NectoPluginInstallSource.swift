//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// A local archive and a repository URL are distinct inputs, not interchangeable paths.
public enum NectoPluginInstallSource: Sendable, Equatable {
    case localPath(String)
    case repositoryURL(String)

    public init(argument: String, local: Bool = false) throws {
        guard !argument.isEmpty else { throw Self.invalidSource }
        if local {
            guard !argument.contains("://") else {
                throw NectoBridgeError(code: .invalidInput, message: "--local requires a filesystem folder or ZIP path.")
            }
            let path = (argument as NSString).expandingTildeInPath
            self = .localPath(URL(fileURLWithPath: path).standardizedFileURL.path)
        } else {
            guard !argument.hasPrefix("/"), !argument.hasPrefix("."), !argument.hasPrefix("~") else {
                throw NectoBridgeError(code: .invalidInput, message: "Remote is the default. Add --local to install a filesystem path.")
            }
            var repository = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            if !repository.contains("://") {
                let first = repository.split(separator: "/").first ?? ""
                if first.contains(".") {
                    repository = "https://" + repository
                } else {
                    let untagged = repository.split(separator: "@", maxSplits: 1).first ?? ""
                    guard untagged.split(separator: "/").count == 2 else { throw Self.invalidSource }
                    repository = "https://github.com/" + repository
                }
            }
            self = .repositoryURL(try Self.validatedRepositoryURL(repository))
        }
    }

    public init(input: NectoJSONValue) throws {
        guard case let .object(fields) = input, fields.count == 1 else { throw Self.invalidSource }
        if let path = fields["path"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") {
            self = .localPath(path)
        } else if let url = fields["repositoryURL"]?.stringValue {
            self = .repositoryURL(try Self.validatedRepositoryURL(url))
        } else { throw Self.invalidSource }
    }

    public var input: NectoJSONValue {
        switch self {
        case let .localPath(path): ["path": .string(path)]
        case let .repositoryURL(url): ["repositoryURL": .string(url)]
        }
    }

    private static func validatedRepositoryURL(_ value: String) throws -> String {
        guard var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port == nil,
              parts.path.split(separator: "/").count >= 2 else {
            throw NectoBridgeError(code: .invalidInput, message: "Use an HTTPS repository URL without credentials, a port, query or fragment.")
        }
        parts.scheme = "https"
        guard let normalized = parts.string else { throw Self.invalidSource }
        return normalized
    }

    private static var invalidSource: NectoBridgeError {
        .init(code: .invalidInput, message: "Provide exactly one absolute local path or HTTPS repository URL.")
    }
}
