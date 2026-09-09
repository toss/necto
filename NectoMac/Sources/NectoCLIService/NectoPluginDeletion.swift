//
// Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel

/// A deletion names a registered plugin; it never accepts a filesystem path.
public struct NectoPluginDeletion: Sendable {
    public let pluginID: String
    public init(pluginID: String) throws {
        guard !pluginID.isEmpty, pluginID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw NectoBridgeError(code: .invalidInput, message: "Pass a plugin ID, not a path or URL.")
        }
        self.pluginID = pluginID
    }
}
