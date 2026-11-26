//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import ArgumentParser
import NectoCLIService
import NectoModel

extension NectoSidebarRequest.Section: ExpressibleByArgument {}

struct Sidebar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "View and organize the saved plugin sidebar.",
        subcommands: [List.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the full sidebar tree, including hidden items.")

        @Option(help: "Sidebar section.") var section: NectoSidebarRequest.Section
        @Flag(name: .long, help: "Print JSON.") var json = false

        func run() async throws {
            let input = NectoSidebarRequest(section: section, action: .list).input
            let value = try await Client().request(.init(kind: .sidebar, input: input))
            if json { print(try encodeJSON(value)); return }
            guard let items = value["items"]?.arrayValue else { throw Client.Failure.protocolError }
            if items.isEmpty { print("No items in the \(section.rawValue) sidebar."); return }
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
}
