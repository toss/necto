//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import ArgumentParser
import NectoCLIService
import NectoModel

extension NectoExporterApproval.ShellAccess: ExpressibleByArgument {}

struct Exporter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Review and decide on pending event collection in the running Necto.",
        subcommands: [Review.self, Approve.self, Reject.self]
    )

    struct Review: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Review the pending exporter, its collection scope and shell access.")
        @Flag(name: .long, help: "Print the review as JSON.") var json = false

        func run() async throws {
            let value = try await Client().request(.init(kind: .reviewExporter))
            if json { print(try encodeJSON(value)); return }
            guard value["pending"]?.boolValue != nil else {
                throw ValidationError("Necto did not return an exporter review.")
            }
            print(Self.render(value))
        }

        static func render(_ value: NectoJSONValue) -> String {
            guard value["pending"] == true else { return "No exporter is pending review." }
            let exporter = value["exporter"] ?? .null
            let collection = value["collection"] ?? .null
            let shell = value["shellAccess"] ?? .null
            let globalFullAccess = shell["globalFullAccess"] == true
            let choices = shell["availableChoices"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let level: String = switch shell["currentLevel"]?.stringValue {
            case "protected": "Protected"
            case "commandApproval": "Command approval"
            case "fullAccess": "Full access"
            default: "Unknown"
            }

            var lines = [
                "Pending exporter  \(exporter["name"]?.stringValue ?? "?")",
                "ID                \(exporter["id"]?.stringValue ?? "?")",
                "Version           \(exporter["version"]?.stringValue ?? "?")",
                "Author            \(exporter["author"]?.stringValue ?? "Unspecified")",
                "Description       \(exporter["description"]?.stringValue ?? "")",
                "Source            \(exporter["source"]?.stringValue ?? "?")",
                "Content hash      \(exporter["contentHash"]?.stringValue ?? "?")",
                "",
                "Event collection",
                "  Includes Necto activity                \(yesNo(collection["includesNecto"]))",
                "  Includes current and future plugins   \(yesNo(collection["includesCurrentAndFuturePlugins"]))",
                "  Preserves plugin exclusions            \(yesNo(collection["preservesExclusions"]))",
                "",
                "Shell access",
                "  Requested          \(yesNo(shell["requested"]))",
                "  Global Full Access \(globalFullAccess ? "On" : "Off")",
                "  Current level      \(level)",
            ]
            if globalFullAccess {
                lines.append("  Global Full Access allows every caller to run any shell command.")
            }
            if choices.isEmpty {
                lines.append("  No --shell-access choice is available.")
            } else {
                lines.append("  Available --shell-access choices")
                for choice in choices {
                    let description: String = switch choice {
                    case "full": "Run any shell command without confirmation."
                    case "commands": "Run only the exact commands listed below."
                    case "none": "Block this exporter's shell requests."
                    default: ""
                    }
                    lines.append("    \(choice)  \(description)")
                }
                if !choices.contains("commands") {
                    lines.append("  Command approval requires a description and valid exact commands for every shell execution operation.")
                }
            }

            let operations = shell["operations"]?.arrayValue ?? []
            if !operations.isEmpty {
                lines += ["", "Shell operations"]
                for operation in operations {
                    let binding = operation["binding"]
                    let version = binding?["version"]?.numberValue.flatMap { Int(exactly: $0) }.map(String.init) ?? "?"
                    lines.append("  \(operation["id"]?.stringValue ?? "?")  (\(binding?["name"]?.stringValue ?? "?") v\(version), \(operation["kind"]?.stringValue ?? "?"))")
                    if let description = operation["description"]?.stringValue, !description.isEmpty {
                        lines.append("    \(description)")
                    }
                    let commands = operation["commands"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let status: String = switch operation["status"]?.stringValue {
                    case "commands": commands.isEmpty ? "The author did not declare exact commands." : "Declared exact commands"
                    case "authorizationRequest": "Can request authorization for a command at runtime."
                    case "unavailable": "Exact commands unavailable."
                    case "unsupportedContract": "Unsupported shell contract."
                    default: "Unknown operation status."
                    }
                    lines.append("    \(status)")
                    if let reason = operation["reason"]?.stringValue, !reason.isEmpty {
                        let explanation = switch reason {
                        case "propertyNotDeclared": "The operation does not declare a command input."
                        case "enumNotDeclared": "The command input does not list exact commands."
                        case "notStringEnum": "The command list must contain only strings."
                        case "unsupportedSchema": "Necto could not read the command input schema."
                        default: reason
                        }
                        lines.append("    \(explanation)")
                    }
                    for command in commands {
                        lines.append("      \(String(reflecting: command))")
                    }
                }
            }

            let approveCommand = choices.isEmpty ? "necto exporter approve" : "necto exporter approve --shell-access <choice>"
            lines += ["", "Run \(approveCommand) to install this exporter and allow event collection.",
                      "Run necto exporter reject to discard this review."]
            return displayText(lines.joined(separator: "\n"))
        }

        private static func yesNo(_ value: NectoJSONValue?) -> String {
            guard let value = value?.boolValue else { return "Unknown" }
            return value ? "Yes" : "No"
        }
    }

    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install the reviewed exporter and allow event collection.")
        @Option(name: .long, help: "Choose shell access when the review requires it.")
        var shellAccess: NectoExporterApproval.ShellAccess?
        @Flag(name: .long, help: "Print the completed installation result as JSON.") var json = false

        func run() async throws {
            let approval = NectoExporterApproval(shellAccess: shellAccess)
            let value = try await Client().request(.init(kind: .approveExporter, input: approval.input))
            guard value["installed"] == true else { throw ValidationError("Necto did not confirm exporter installation.") }
            if json { print(try encodeJSON(value)); return }
            print(displayText("Installed exporter \(value["pluginID"]?.stringValue ?? "?") \(value["version"]?.stringValue ?? "")"))
        }
    }

    struct Reject: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discard the current exporter review.")
        @Flag(name: .long, help: "Print the rejection result as JSON.") var json = false

        func run() async throws {
            let value = try await Client().request(.init(kind: .rejectExporter))
            guard value["rejected"] == true else { throw ValidationError("Necto did not confirm exporter rejection.") }
            if json { print(try encodeJSON(value)); return }
            print(displayText("Discarded the review for exporter \(value["pluginID"]?.stringValue ?? "?")."))
        }
    }
}
