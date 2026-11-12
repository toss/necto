//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// The single source of truth for the wire protocol.
///
/// Necto speaks exactly one protocol version. It does not negotiate with peers on
/// other versions; a mismatch fails the connection instead.
public enum NectoProtocol {
    public static let name = "necto"
    public static let currentVersion = 1

    public static func isSupported(version: Int) -> Bool {
        version == currentVersion
    }
}
