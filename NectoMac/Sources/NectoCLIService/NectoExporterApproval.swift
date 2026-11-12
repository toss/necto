//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel

public struct NectoExporterApproval: Sendable {
    public enum ShellAccess: String, Sendable, CaseIterable {
        case full
        case commands
        case none
    }

    public let shellAccess: ShellAccess?

    public init(shellAccess: ShellAccess?) {
        self.shellAccess = shellAccess
    }

    public init(input: NectoJSONValue) throws {
        if input == .null || input == .object([:]) {
            self.init(shellAccess: nil)
            return
        }
        guard let fields = input.objectValue, fields.count == 1,
              let rawValue = fields["shellAccess"]?.stringValue,
              let shellAccess = ShellAccess(rawValue: rawValue) else {
            throw NectoBridgeError(code: .invalidInput, message: "Exporter approval only accepts shellAccess set to full, commands, or none.")
        }
        self.init(shellAccess: shellAccess)
    }

    public var input: NectoJSONValue {
        guard let shellAccess else { return .object([:]) }
        return ["shellAccess": .string(shellAccess.rawValue)]
    }
}
