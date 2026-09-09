//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation
import CryptoKit

/// Key-value storage that only the plugin that wrote it can read.
///
/// The namespace is never chosen by JavaScript. It is derived from the plugin
/// principal, and from the selected target when there is one, so two plugins cannot
/// reach each other's values and the same plugin pointed at two apps keeps them
/// apart. A plugin installed from a different source is a different principal even
/// with the same id.
public actor NectoPluginStorage {
    private let directory: URL
    private var loaded: [String: [String: NectoJSONValue]] = [:]

    /// Defaults to Application Support. Tests pass a temporary directory rather than
    /// writing into the real one.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appending(path: "Necto/PluginStorage")
        }
    }

    public func value(forKey key: String, scope: Scope) -> NectoJSONValue? {
        values(for: scope)[key]
    }

    public func keys(matching prefix: String?, scope: Scope) -> [String] {
        values(for: scope)
            .keys
            .filter { prefix.map($0.hasPrefix) ?? true }
            .sorted()
    }

    public func setValue(_ value: NectoJSONValue, forKey key: String, scope: Scope) throws {
        var values = values(for: scope)
        values[key] = value
        try write(values, for: scope)
    }

    public func removeValue(forKey key: String, scope: Scope) throws {
        var values = values(for: scope)
        values.removeValue(forKey: key)
        try write(values, for: scope)
    }

    /// What a set of values belongs to.
    public struct Scope: Sendable, Hashable {
        let principal: NectoPluginPrincipal
        let target: NectoTarget?
        let isPluginWide: Bool

        public init(principal: NectoPluginPrincipal, target: NectoTarget?, isPluginWide: Bool = false) {
            self.principal = principal
            self.target = isPluginWide ? nil : target
            self.isPluginWide = isPluginWide
        }

        /// Stable across processes; Swift's Hasher has a per-process random seed.
        var identity: String {
            if isPluginWide {
                let data = (try? JSONEncoder().encode([principal.pluginID, principal.sourceIdentity])) ?? Data()
                return "plugin-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            var digest = SHA256()
            digest.update(data: Data("NectoPluginStorage/v1".utf8))
            for field in [principal.pluginID, principal.sourceIdentity, target?.deviceID, target?.appBundleID] {
                guard let field else { digest.update(data: [0]); continue }
                let bytes = Data(field.utf8)
                digest.update(data: [1])
                withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { digest.update(bufferPointer: $0) }
                digest.update(data: bytes)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private func values(for scope: Scope) -> [String: NectoJSONValue] {
        if let cached = loaded[scope.identity] { return cached }

        let values = (try? Data(contentsOf: file(for: scope)))
            .flatMap { try? JSONDecoder().decode([String: NectoJSONValue].self, from: $0) }
            ?? [:]
        loaded[scope.identity] = values
        return values
    }

    private func write(_ values: [String: NectoJSONValue], for scope: Scope) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: file(for: scope), options: .atomic)
        loaded[scope.identity] = values
    }

    private func file(for scope: Scope) -> URL {
        directory.appending(path: "\(scope.identity).json")
    }
}
