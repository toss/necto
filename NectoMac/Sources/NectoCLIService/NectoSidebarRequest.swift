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
        case move(Move)
    }

    public enum FolderEdit: Sendable {
        case create(name: String, parentID: UUID?)
        case rename(id: UUID, name: String)
        case delete(id: UUID)
    }

    public enum ItemID: Sendable {
        case plugin(String)
        case folder(UUID)

        public init(reference: String) throws {
            if reference.hasPrefix("plugin:"), reference.count > "plugin:".count {
                self = .plugin(String(reference.dropFirst("plugin:".count)))
            } else if reference.hasPrefix("folder:"), let id = UUID(uuidString: String(reference.dropFirst("folder:".count))) {
                self = .folder(id)
            } else {
                throw NectoBridgeError(code: .invalidInput, message: "Use plugin:<id> or folder:<uuid> from sidebar list.")
            }
        }

        public var reference: String {
            switch self {
            case .plugin(let id): "plugin:\(id)"
            case .folder(let id): "folder:\(id.uuidString)"
            }
        }
    }

    public struct Move: Sendable {
        public let item: ItemID
        public let parentID: UUID?
        public let before: ItemID?
        public let after: ItemID?

        public init(item: ItemID, parentID: UUID? = nil, before: ItemID? = nil, after: ItemID? = nil) throws {
            guard before == nil || after == nil else {
                throw NectoBridgeError(code: .invalidInput, message: "Specify either before or after, or omit both.")
            }
            self.item = item
            self.parentID = parentID
            self.before = before
            self.after = after
        }
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
        case "move":
            action = .move(try Move(
                item: Self.itemID(input["item"], field: "item"),
                parentID: input["parentID"].map { try Self.folderID($0, field: "parentID") },
                before: input["before"].map { try Self.itemID($0, field: "before") },
                after: input["after"].map { try Self.itemID($0, field: "after") }
            ))
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
        case .move(let move):
            fields["action"] = "move"
            fields["item"] = .string(move.item.reference)
            fields["parentID"] = move.parentID.map { .string($0.uuidString) }
            fields["before"] = move.before.map { .string($0.reference) }
            fields["after"] = move.after.map { .string($0.reference) }
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

    private static func itemID(_ value: NectoJSONValue?, field: String) throws -> ItemID {
        guard let reference = value?.stringValue else {
            throw NectoBridgeError(code: .invalidInput, message: "\(field) must be a sidebar item ID.")
        }
        return try ItemID(reference: reference)
    }
}
