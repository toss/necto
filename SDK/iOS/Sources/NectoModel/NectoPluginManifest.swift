//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// The typed form of `manifest.json`.
///
/// See `docs/plugin-manifest.md` for the specification.
public struct NectoPluginManifest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public struct Icon: Sendable, Hashable, Codable {
        /// An SF Symbols name.
        public let systemName: String

        public init(systemName: String) {
            self.systemName = systemName
        }
    }

    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let description: String
    public let version: String
    public let author: String
    public let authorURL: String?
    public let icon: Icon
    public let assets: [String]
    public let allowedOrigins: [String]
    public let operations: [NectoOperation]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, description, version, author
        case authorURL = "authorUrl"
        case icon, assets, allowedOrigins, operations
    }

    public init(
        schemaVersion: Int = NectoPluginManifest.currentSchemaVersion,
        id: String,
        name: String,
        description: String,
        version: String,
        author: String,
        authorURL: String? = nil,
        icon: Icon,
        assets: [String],
        allowedOrigins: [String],
        operations: [NectoOperation]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.authorURL = authorURL
        self.icon = icon
        self.assets = assets
        self.allowedOrigins = allowedOrigins
        self.operations = operations
    }

    /// A plugin needs a connected app as soon as one operation binds to an app contract.
    /// This is derived from the bindings rather than declared again in the manifest.
    public var requiresTarget: Bool {
        operations.contains { $0.binding.requiresTarget }
    }

    public func operation(id operationID: String) -> NectoOperation? {
        operations.first { $0.id == operationID }
    }
}

public enum NectoManifestValidationError: Sendable, Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case invalidIdentifier(String)
    case emptyField(String)
    case invalidVersion(field: String, value: String)
    case noOperations
    case duplicateOperationID(String)
    case negativeTimeout(operationID: String)
    case unknownBridgeOwner(operationID: String, name: String)
    case duplicateBinding(operationID: String, name: String)
    case invalidOrigin(String)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(value):
            "schemaVersion \(value) is not supported. Only \(NectoPluginManifest.currentSchemaVersion) is accepted."
        case let .invalidIdentifier(value):
            "Identifier '\(value)' may only contain A-Z, a-z, 0-9, '.', '_' and '-'."
        case let .emptyField(field):
            "\(field) must not be empty."
        case let .invalidVersion(field, value):
            "\(field) '\(value)' is not a valid semantic version."
        case .noOperations:
            "At least one operation is required."
        case let .duplicateOperationID(value):
            "Duplicate operation id '\(value)'."
        case let .negativeTimeout(operationID):
            "Operation '\(operationID)' must declare a timeoutMs of 0 or greater."
        case let .unknownBridgeOwner(operationID, name):
            "Operation '\(operationID)' binds to '\(name)', which names no owner. "
                + "A bridge is called '\(NectoBridgeKind.device.prefix)…' or '\(NectoBridgeKind.desktop.prefix)…'."
        case let .duplicateBinding(operationID, name):
            "Operation '\(operationID)' binds to '\(name)', which another operation already binds to."
        case let .invalidOrigin(value):
            "allowedOrigins entry '\(value)' must be 'self' or an https origin."
        }
    }
}

public extension NectoPluginManifest {
    /// Checks the manifest for internal consistency.
    /// Whether it can be installed — whether anything provides these bridges, and whether
    /// the person agrees to them — is decided by the runtime.
    func validate() throws(NectoManifestValidationError) {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw .unsupportedSchemaVersion(schemaVersion)
        }
        guard Self.isValidIdentifier(id) else { throw .invalidIdentifier(id) }

        for (field, value) in [("name", name), ("description", description), ("author", author)]
        where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw .emptyField(field)
        }

        guard NectoSemanticVersion(version) != nil else {
            throw .invalidVersion(field: "version", value: version)
        }
        for origin in allowedOrigins where !Self.isValidOrigin(origin) {
            throw .invalidOrigin(origin)
        }

        var seenIDs: Set<String> = []
        var seenBindings: Set<String> = []
        for operation in operations {
            guard Self.isValidIdentifier(operation.id) else { throw .invalidIdentifier(operation.id) }
            guard seenIDs.insert(operation.id).inserted else {
                throw .duplicateOperationID(operation.id)
            }
            guard operation.timeoutMs >= 0 else { throw .negativeTimeout(operationID: operation.id) }

            // The binding is the whole declaration, so it has to say who answers it and
            // it has to be the only operation saying it.
            let name = operation.binding.name
            guard operation.binding.type != nil else {
                throw .unknownBridgeOwner(operationID: operation.id, name: name)
            }
            guard seenBindings.insert(operation.binding.identity).inserted else {
                throw .duplicateBinding(operationID: operation.id, name: name)
            }
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isLetter && character.isASCII
                || character.isNumber && character.isASCII
                || character == "." || character == "_" || character == "-"
        }
    }

    private static func isValidOrigin(_ value: String) -> Bool {
        if value == "self" { return true }
        guard let url = URLComponents(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              host.allSatisfy({ "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]".contains($0) }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        return true
    }
}
