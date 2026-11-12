//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// Who owns a bridge.
public enum NectoBridgeKind: String, Sendable, Codable, CaseIterable {
    /// Provided by the Mac app.
    case desktop
    /// Registered by a connected app. Requires a target.
    case device

    /// The prefix every bridge of this kind is named under.
    public var prefix: String { "necto.\(rawValue)." }

    /// Which kind a name belongs to, or nil when it belongs to neither.
    public static func owning(_ name: String) -> NectoBridgeKind? {
        allCases.first { name.hasPrefix($0.prefix) }
    }
}

/// Identifies one bridge.
///
/// The owner is in the name rather than beside it: `necto.device.events.list` is called
/// as `necto.device.send("events.list")`, so what a manifest declares and what a plugin
/// writes are the same string, and neither can drift from the other.
///
/// `version` is not a release number. It counts breaking changes — the times a bridge
/// changed so much that an older reader cannot make sense of it — so it stays put for
/// as long as possible, and a mismatch is a refusal rather than a negotiation.
public struct NectoBridgeBinding: Sendable, Hashable, Codable {
    public let name: String
    public let version: Int

    public init(name: String, version: Int) {
        self.name = name
        self.version = version
    }

    /// Who answers this bridge, read from the name.
    public var type: NectoBridgeKind? { NectoBridgeKind.owning(name) }

    /// App contracts cannot be called without a selected target.
    public var requiresTarget: Bool { type == .device }

    /// Identity for provider lookup. Two versions of a name are two bridges.
    public var identity: String { "\(name)@\(version)" }
}

/// The route a provider claims to satisfy.
///
/// Name, version and kind select executable code. Payload schemas remain in catalog
/// version 1 for wire compatibility, while the installed manifest is the runtime's
/// authority for validating both sides.
public struct NectoBridgeDescriptor: Sendable, Hashable, Codable {
    public let binding: NectoBridgeBinding
    public let kind: NectoOperationKind
    public let inputSchema: NectoJSONValue
    public let outputSchema: NectoJSONValue

    public init(
        binding: NectoBridgeBinding,
        kind: NectoOperationKind,
        inputSchema: NectoJSONValue = .object([:]),
        outputSchema: NectoJSONValue = .object([:])
    ) {
        self.binding = binding
        self.kind = kind
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    public var name: String { binding.name }
    public var version: Int { binding.version }
    public var identity: String { binding.identity }

    /// Why this descriptor cannot route a manifest operation, or nil when it can.
    ///
    /// Returns a reason rather than a bool so a mismatch can be reported precisely.
    /// A silent refusal here is very hard to debug from the plugin side.
    public func mismatch(with operation: NectoOperation) -> String? {
        if binding.name != operation.binding.name {
            return "is named '\(binding.name)', the manifest declares '\(operation.binding.name)'"
        }
        if binding.version != operation.binding.version {
            return "is version \(binding.version), the manifest declares \(operation.binding.version)"
        }
        if kind != operation.kind {
            return "is a \(kind.rawValue), the manifest declares a \(operation.kind.rawValue)"
        }
        return nil
    }
}

/// A provider's descriptors as they travel over the wire.
///
/// Versioned on its own, because the catalog format, the wire protocol and the
/// manifest format evolve separately and folding them into one number would tie
/// unrelated changes together.
public struct NectoBridgeCatalog: Sendable, Hashable, Codable {
    public static let currentVersion = 1

    public let catalogVersion: Int
    public let bridges: [NectoBridgeDescriptor]

    public init(catalogVersion: Int = NectoBridgeCatalog.currentVersion, bridges: [NectoBridgeDescriptor]) {
        self.catalogVersion = catalogVersion
        self.bridges = bridges
    }
}
