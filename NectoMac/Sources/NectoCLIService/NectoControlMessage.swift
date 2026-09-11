//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

public enum NectoCLIShell {
    public static let pluginID = "im.toss.necto.cli"
    public static let sourceIdentity = "necto-cli"
    public static let operationID = "shell.execute"
}

/// One request over the control socket.
///
/// The vocabulary mirrors the web panel's, not the SDK's: a caller names a plugin and
/// an operation id from its manifest, and the registry resolves the rest. The CLI is
/// a panel that happens to live in a terminal.
public struct NectoControlRequest: Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// Connected apps and devices.
        case targets
        /// Scoped plugin summaries, or operation help selected by plugin and operation IDs.
        case plugins
        /// Install from a local path or repository URL through the app's approval flow.
        case installPlugin
        /// Remove an installed desktop plugin through the app's removal path.
        case deletePlugin
        /// Call an operation that answers once.
        case invoke
        /// Follow an operation that streams; events arrive until `end`.
        case subscribe
        /// Cancel a pending request with the same `id`.
        case cancel
    }

    /// Correlates responses on a connection that interleaves them.
    public let id: String
    public let kind: Kind
    public let pluginID: String?
    public let operationID: String?
    public let input: NectoJSONValue?
    /// The plugin's owning app, paired with an explicit device ID.
    public let app: String?
    /// A device ID returned by target discovery.
    public let device: String?
    /// Select installed desktop plugins instead of plugins carried by an app.
    public let desktop: Bool?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        pluginID: String? = nil,
        operationID: String? = nil,
        input: NectoJSONValue? = nil,
        app: String? = nil,
        device: String? = nil,
        desktop: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.pluginID = pluginID
        self.operationID = operationID
        self.input = input
        self.app = app
        self.device = device
        self.desktop = desktop
    }
}

/// One reply. A request sees exactly one `result` or `error`, except `subscribe`,
/// which sees any number of `event`s and then one `end` or `error`.
public struct NectoControlResponse: Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case result
        case event
        case end
        case error
    }

    public struct Failure: Sendable, Codable {
        public let code: String
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public let id: String
    public let kind: Kind
    public let value: NectoJSONValue?
    public let error: Failure?

    public init(id: String, kind: Kind, value: NectoJSONValue? = nil, error: Failure? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.error = error
    }
}

public enum NectoControlSocket {
    /// Beside the plugins folder, because they share a trust boundary: whoever can
    /// write one can already write the other.
    public static func url() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Necto/necto.sock")
    }
}
