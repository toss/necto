//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// Host-owned trust record. Never read an installation ID from a plugin's files.
public struct NectoLocalPluginInstallation: Codable, Equatable, Sendable {
    /// The repository a plugin was fetched from, and the release it came out of.
    ///
    /// Files chosen on this Mac name no source, so nothing can be said about where
    /// they came from and the record's own ID stands in. A repository can be named,
    /// and naming it is what lets two plugins that chose the same ID stay apart —
    /// and what makes a move to a different repository a different plugin, which is
    /// the point: permissions were given to a source, not to a string.
    public struct Origin: Codable, Equatable, Sendable {
        public let host: String
        public let owner: String
        public let repository: String
        public let tag: String

        public init(host: String, owner: String, repository: String, tag: String) {
            self.host = host
            self.owner = owner
            self.repository = repository
            self.tag = tag
        }

        /// The tag is deliberately absent: an update is the same installation, and a
        /// plugin that has to be re-approved on every release teaches people to click
        /// through the one screen that matters.
        public var identity: String { "git:\(host)/\(owner)/\(repository)" }

        public var label: String { "\(host)/\(owner)/\(repository)" }
    }

    public let id: UUID
    public let pluginID: String
    public let directoryPath: String
    public private(set) var approvedContentHash: String
    /// Absent for files chosen on this Mac, which is most of them.
    public private(set) var origin: Origin?

    public init(
        pluginID: String,
        directoryPath: String,
        approvedContentHash: String,
        origin: Origin? = nil
    ) {
        id = UUID()
        self.pluginID = pluginID
        self.directoryPath = directoryPath
        self.approvedContentHash = approvedContentHash
        self.origin = origin
    }

    public var principal: NectoPluginPrincipal {
        NectoPluginPrincipal(pluginID: pluginID, sourceIdentity: origin?.identity ?? "local:\(id.uuidString)")
    }

    public func matches(pluginID: String, directoryPath: String) -> Bool {
        self.pluginID == pluginID && self.directoryPath == directoryPath
    }

    /// Call only after the user confirms that these files update this installation.
    ///
    /// The origin is stated every time and replaces whatever was there, because an
    /// update can arrive from somewhere else than the one before it: a plugin first
    /// dragged in and later followed from its source, or — the case that matters —
    /// files chosen on this Mac replacing a plugin that came from a repository. Those
    /// files name no source, and keeping the old one would run them under a
    /// repository's identity and hand them its permissions.
    public mutating func approveUpdate(contentHash: String, origin: Origin?) {
        approvedContentHash = contentHash
        self.origin = origin
    }
}
