//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import NectoSDK

/// A tap configuration discovered from a native recognizer, not an exhaustive capability list.
public struct NectoControlTapGesture: Sendable, Equatable {
    public let touchCount: Int
    public let tapCount: Int

    public init(touchCount: Int, tapCount: Int) {
        self.touchCount = touchCount
        self.tapCount = tapCount
    }
}

/// A visible accessibility action candidate. IDs are opaque and stable for the element's lifetime;
/// clients must refresh after acting because availability and geometry can change.
public struct NectoControlTarget: Sendable {
    public let id: String
    public let role: String
    public let label: String?
    public let identifier: String?
    /// Visible bounds in window coordinates: x, y, width, height.
    public let frame: (x: Double, y: Double, width: Double, height: Double)
    public let actions: [String]
    public let tapGestures: [NectoControlTapGesture]
    public let value: String?
    public let isSecure: Bool

    public init(
        id: String,
        role: String,
        label: String? = nil,
        identifier: String? = nil,
        frame: (x: Double, y: Double, width: Double, height: Double),
        actions: [String],
        tapGestures: [NectoControlTapGesture] = [],
        value: String? = nil,
        isSecure: Bool = false
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.identifier = identifier
        self.frame = frame
        self.actions = actions
        self.tapGestures = tapGestures
        self.value = isSecure ? nil : value
        self.isSecure = isSecure
    }
}

/// Discovers action targets and dispatches tap, input, swipe, and back requests.
/// UIKit support is included; other UI implementations can supply the same contract.
public final class NectoUIControlPlugin: NectoPluginable, @unchecked Sendable {
    public let id = "control"
    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module, subdirectory: "Panels/control") }

    private let actionTargets: @Sendable () async -> [NectoControlTarget]
    private let readAccessibility: @Sendable () async -> [NectoAccessibilityItem]
    private let action: @Sendable (String, NectoJSONValue) async throws -> NectoJSONValue

    public init(
        actionTargets: @escaping @Sendable () async -> [NectoControlTarget],
        readAccessibility: @escaping @Sendable () async -> [NectoAccessibilityItem],
        action: @escaping @Sendable (String, NectoJSONValue) async throws -> NectoJSONValue
    ) {
        self.actionTargets = actionTargets
        self.readAccessibility = readAccessibility
        self.action = action
    }

    #if canImport(UIKit)
    public convenience init() {
        let runtime = NectoControlRuntime()
        self.init(
            actionTargets: { await runtime.snapshot() },
            readAccessibility: { await runtime.readAccessibility() },
            action: { operation, input in try await runtime.perform(operation, input) }
        )
    }
    #endif

    public func register(_ necto: NectoHandler) {
        necto.handle("control.actionTargets") { [self] input in
            let query = input["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let available = await actionTargets().filter { !$0.actions.isEmpty }
            let matches = query.isEmpty ? available : available.filter { element in
                [element.label, element.identifier, element.role].contains {
                    $0?.localizedCaseInsensitiveContains(query) == true
                }
            }
            return ["targets": .array(matches.map(Self.encode))]
        }
        necto.handle("control.readAccessibility") { [self] input in
            let query = input["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let items = await readAccessibility()
            let matches = query.isEmpty ? items : items.filter { item in
                [item.label, item.identifier, item.role, item.value].contains {
                    $0?.localizedCaseInsensitiveContains(query) == true
                }
            }
            return ["items": .array(matches.map { $0.json })]
        }
        for operation in ["tap", "input", "swipe", "back"] {
            necto.handle("control.\(operation)") { [self] input in
                try await action(operation, input)
            }
        }
    }

    private static func encode(_ element: NectoControlTarget) -> NectoJSONValue {
        var fields: [String: NectoJSONValue] = [
            "id": .string(element.id),
            "role": .string(element.role),
            "frame": .array([element.frame.x, element.frame.y, element.frame.width, element.frame.height]
                .map { .number($0.isFinite ? $0 : 0) }),
            "actions": .array(element.actions.map(NectoJSONValue.string)),
        ]
        if !element.tapGestures.isEmpty {
            fields["tapGestures"] = .array(element.tapGestures.map {
                ["touchCount": .number(Double($0.touchCount)), "tapCount": .number(Double($0.tapCount))]
            })
        }
        if let label = element.label { fields["label"] = .string(label) }
        if let identifier = element.identifier { fields["identifier"] = .string(identifier) }
        if let value = element.value, !element.isSecure { fields["value"] = .string(value) }
        if element.isSecure { fields["isSecure"] = true }
        return .object(fields)
    }
}
