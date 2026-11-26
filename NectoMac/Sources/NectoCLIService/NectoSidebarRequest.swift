//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// A host sidebar command, scoped independently of the selected app or window.
public struct NectoSidebarRequest: Sendable {
    public enum Section: String, Sendable, CaseIterable {
        case device
        case desktop
    }

    public enum Action: Sendable {
        case list
        case folder(FolderEdit)
    }

    public enum FolderEdit: Sendable {
        case create(name: String, parentID: UUID?)
        case rename(id: UUID, name: String)
        case delete(id: UUID)
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
        let action: Action
        switch input["action"]?.stringValue {
        case "list":
            action = .list
        case "createFolder":
            let parentID = try input["parentID"].map { try Self.folderID($0, field: "parentID") }
            action = .folder(.create(name: try Self.folderName(input), parentID: parentID))
        case "renameFolder":
            action = .folder(.rename(id: try Self.folderID(input["folderID"], field: "folderID"),
                                     name: try Self.folderName(input)))
        case "deleteFolder":
            action = .folder(.delete(id: try Self.folderID(input["folderID"], field: "folderID")))
        default:
            throw NectoBridgeError(code: .invalidInput, message: "Unrecognized sidebar action.")
        }
        self.init(section: section, action: action)
    }

    public var input: NectoJSONValue {
        var fields: [String: NectoJSONValue] = ["section": .string(section.rawValue)]
        switch action {
        case .list:
            fields["action"] = "list"
        case .folder(.create(let name, let parentID)):
            fields["action"] = "createFolder"
            fields["name"] = .string(name)
            fields["parentID"] = parentID.map { .string($0.uuidString) }
        case .folder(.rename(let id, let name)):
            fields["action"] = "renameFolder"
            fields["folderID"] = .string(id.uuidString)
            fields["name"] = .string(name)
        case .folder(.delete(let id)):
            fields["action"] = "deleteFolder"
            fields["folderID"] = .string(id.uuidString)
        }
        return .object(fields)
    }

    private static func folderID(_ value: NectoJSONValue?, field: String) throws -> UUID {
        guard let id = value?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw NectoBridgeError(code: .invalidInput, message: "\(field) must be a folder UUID.")
        }
        return id
    }

    private static func folderName(_ input: NectoJSONValue) throws -> String {
        guard let name = input["name"]?.stringValue else {
            throw NectoBridgeError(code: .invalidInput, message: "Specify a folder name.")
        }
        return name
    }
}
