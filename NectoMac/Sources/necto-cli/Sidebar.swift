//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import ArgumentParser
import Foundation
import NectoCLIService
import NectoModel

extension NectoSidebarRequest.Section: ExpressibleByArgument {}

struct Sidebar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "View and organize the saved plugin sidebar.",
        subcommands: [List.self, Folder.self, Move.self]
    )

    struct Options: ParsableArguments {
        @Option(help: "Sidebar section.") var section: NectoSidebarRequest.Section
        @Flag(name: .long, help: "Print JSON.") var json = false

        func send(_ action: NectoSidebarRequest.Action) async throws -> NectoJSONValue {
            let input = NectoSidebarRequest(section: section, action: action).input
            return try await Client().request(.init(kind: .sidebar, input: input))
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the full sidebar tree, including hidden items.")
        @OptionGroup var options: Options

        func run() async throws {
            let value = try await options.send(.list)
            if options.json { print(try encodeJSON(value)); return }
            guard let items = value["items"]?.arrayValue else { throw Client.Failure.protocolError }
            if items.isEmpty { print("No items in the \(options.section.rawValue) sidebar."); return }
            Self.printItems(items, indent: "")
        }

        private static func printItems(_ items: [NectoJSONValue], indent: String) {
            for item in items {
                guard let kind = item["kind"]?.stringValue, let id = item["id"]?.stringValue else { continue }
                let name = item["name"]?.stringValue ?? id
                let status: String
                if kind == "folder" {
                    status = item["isCollapsed"]?.boolValue == true ? " (collapsed)" : ""
                } else {
                    let disabled = item["enabled"]?.boolValue == false ? " (disabled)" : ""
                    let unavailable = item["available"]?.boolValue == false ? " (unavailable)" : ""
                    status = disabled + unavailable
                }
                print(displayText("\(indent)\(name) [\(kind):\(id)]\(status)"))
                if let children = item["children"]?.arrayValue { printItems(children, indent: indent + "  ") }
            }
        }
    }

    struct Folder: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create, rename or delete sidebar folders.",
            subcommands: [Create.self, Rename.self, Delete.self]
        )

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Create a folder with a unique name among its siblings.")
            @Argument(help: "Name for the new folder.") var name: String
            @Option(help: "Parent folder UUID. Omit for the section root.", transform: Sidebar.folderUUID)
            var parent: UUID?
            @OptionGroup var options: Options

            func run() async throws { try await edit(.create(name: name, parentID: parent), using: options) }
        }

        struct Rename: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Rename a folder by UUID.")
            @Argument(help: "The folder UUID from sidebar list.", transform: Sidebar.folderUUID) var folderID: UUID
            @Argument(help: "New folder name.") var name: String
            @OptionGroup var options: Options

            func run() async throws { try await edit(.rename(id: folderID, name: name), using: options) }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Delete a folder and promote its direct children in place.")
            @Argument(help: "The folder UUID from sidebar list.", transform: Sidebar.folderUUID) var folderID: UUID
            @OptionGroup var options: Options

            func run() async throws { try await edit(.delete(id: folderID), using: options) }
        }

        private static func edit(_ command: NectoSidebarRequest.FolderEdit, using options: Options) async throws {
            let value = try await options.send(.folder(command))
            guard let id = value["folderID"]?.stringValue, let name = value["name"]?.stringValue,
                  let changed = value["changed"]?.boolValue else { throw Client.Failure.protocolError }
            if options.json { print(try encodeJSON(value)); return }
            let action: String
            switch command {
            case .create: action = "Created"
            case .rename: action = changed ? "Renamed" : "Unchanged"
            case .delete: action = "Deleted"
            }
            print(displayText("\(action) \(name) [folder:\(id)]"))
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move or reorder one sidebar item.",
            discussion: "With no anchor, place the item first in the specified folder or last at the section root. "
                + "An anchor selects its own parent unless --parent is specified, in which case they must agree."
        )
        @Argument(help: "Item from sidebar list, as plugin:<id> or folder:<uuid>.",
                  transform: NectoSidebarRequest.ItemID.init(reference:))
        var item: NectoSidebarRequest.ItemID
        @Option(help: "Destination folder UUID.", transform: Sidebar.folderUUID) var parent: UUID?
        @Option(help: "Place immediately before this item ID.", transform: NectoSidebarRequest.ItemID.init(reference:))
        var before: NectoSidebarRequest.ItemID?
        @Option(help: "Place immediately after this item ID.", transform: NectoSidebarRequest.ItemID.init(reference:))
        var after: NectoSidebarRequest.ItemID?
        @OptionGroup var options: Options

        func run() async throws {
            let move = try NectoSidebarRequest.Move(item: item, parentID: parent, before: before, after: after)
            let value = try await options.send(.move(move))
            guard let reference = value["item"]?.stringValue, let changed = value["changed"]?.boolValue else {
                throw Client.Failure.protocolError
            }
            if options.json { print(try encodeJSON(value)); return }
            let item = value["name"]?.stringValue.map { "\($0) [\(reference)]" } ?? reference
            if changed {
                let destination = value["parentID"]?.stringValue.map { "folder:\($0)" } ?? "the section root"
                print(displayText("Moved \(item) to \(destination)"))
            } else {
                print(displayText("Unchanged \(item)"))
            }
        }
    }

    private static func folderUUID(_ argument: String) throws -> UUID {
        guard let id = UUID(uuidString: argument) else { throw ValidationError("Expected a folder UUID.") }
        return id
    }
}
