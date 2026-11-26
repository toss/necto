//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel

/// A host sidebar command, scoped independently of the selected app or window.
public struct NectoSidebarRequest: Sendable {
    public enum Section: String, Sendable, CaseIterable {
        case device
        case desktop
    }

    public enum Action: String, Sendable {
        case list
    }

    public let section: Section
    public let action: Action

    public init(section: Section, action: Action) {
        self.section = section
        self.action = action
    }

    public init(input: NectoJSONValue) throws {
        guard let section = input["section"]?.stringValue.flatMap(Section.init(rawValue:)) else {
            throw NectoBridgeError(code: .invalidInput, message: "Specify the device or desktop sidebar section.")
        }
        guard let action = input["action"]?.stringValue.flatMap(Action.init(rawValue:)) else {
            throw NectoBridgeError(code: .invalidInput, message: "Unrecognized sidebar action.")
        }
        self.init(section: section, action: action)
    }

    public var input: NectoJSONValue {
        ["section": .string(section.rawValue), "action": .string(action.rawValue)]
    }
}
