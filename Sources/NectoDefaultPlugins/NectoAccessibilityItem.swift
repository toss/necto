//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel

/// Read-only accessibility content. An item is not an action target or a view-tree node.
public struct NectoAccessibilityItem: Sendable {
    public let role: String
    public let label: String?
    public let identifier: String?
    public let value: String?
    public let isSecure: Bool

    public init(role: String, label: String? = nil, identifier: String? = nil,
                value: String? = nil, isSecure: Bool = false) {
        self.role = role
        self.label = label
        self.identifier = identifier
        self.value = isSecure ? nil : value
        self.isSecure = isSecure
    }

    var json: NectoJSONValue {
        var fields: [String: NectoJSONValue] = ["role": .string(role)]
        if let label { fields["label"] = .string(label) }
        if let identifier { fields["identifier"] = .string(identifier) }
        if let value, !isSecure { fields["value"] = .string(value) }
        if isSecure { fields["isSecure"] = true }
        return .object(fields)
    }
}
