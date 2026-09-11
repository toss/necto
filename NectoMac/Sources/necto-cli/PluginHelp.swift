//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import ArgumentParser
import NectoCLIService
import NectoModel
import NectoTransport
import Foundation

struct TargetOptions: ParsableArguments {
    @Option(name: .long, help: "Device ID from necto device list. Requires --app.") var device: String?
    @Option(name: .long, help: "App bundle ID from necto device list. Requires --device.") var app: String?
    @Flag(name: .long, help: "Select installed desktop plugins, without an app.") var desktop = false

    func validate() throws {
        if desktop {
            guard app == nil, device == nil else {
                throw ValidationError("--desktop cannot be combined with --device or --app.")
            }
        } else if app?.isEmpty != false || device?.isEmpty != false {
            throw ValidationError("Pass both --device and --app, or --desktop. Run necto device list to find targets.")
        }
    }
}

struct InputOptions: ParsableArguments {
    @Option(name: .long, help: "Input as JSON. Defaults to {}.") var input: String?
    @Option(name: .long, help: "Read JSON from a file, or - for standard input. Cannot combine with --input.") var inputFile: String?

    func value() throws -> NectoJSONValue {
        guard input == nil || inputFile == nil else {
            throw ValidationError("Use either --input or --input-file, not both.")
        }
        guard let inputFile else { return try parseInput(input) }
        let handle: FileHandle
        do { handle = inputFile == "-" ? .standardInput : try FileHandle(forReadingFrom: URL(filePath: inputFile)) }
        catch { throw ValidationError("Could not open --input-file: \(error.localizedDescription)") }
        defer { if inputFile != "-" { try? handle.close() } }
        var data = Data()
        let maximum = NectoMessageSession.maximumMessageBytes
        while data.count <= maximum {
            guard let chunk = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximum else { throw ValidationError("Input exceeds the control message size limit.") }
        do { return try JSONDecoder().decode(NectoJSONValue.self, from: data) }
        catch { throw ValidationError("--input-file must contain valid JSON.") }
    }
}

struct Device: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Discover connected devices and their apps.", subcommands: [List.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List connected devices, IDs and app bundle IDs.")
        @Flag(name: .long, help: "Print JSON.") var json = false

        static func grouped(_ value: NectoJSONValue) -> NectoJSONValue {
            let groups = Dictionary(grouping: value["targets"]?.arrayValue ?? []) { $0["deviceID"]?.stringValue ?? "" }
            return ["devices": .array(groups.keys.sorted().map { id in
                let targets = groups[id] ?? []
                return ["id": .string(id), "name": targets.first?["deviceName"] ?? .string(id),
                        "apps": .array(targets.map {
                            ["bundleID": $0["appBundleID"] ?? .null, "name": $0["appName"] ?? .null]
                        }.sorted { ($0["bundleID"]?.stringValue ?? "") < ($1["bundleID"]?.stringValue ?? "") })]
            })]
        }

        func run() async throws {
            let value = Self.grouped(try await Client().request(.init(kind: .targets)))
            if json { print(try encodeJSON(value)); return }
            let devices = value["devices"]?.arrayValue ?? []
            guard !devices.isEmpty else { print("No connected apps. Launch an SDK-enabled app and keep Necto running."); return }
            for device in devices {
                print(displayText("\(device["id"]?.stringValue ?? "?")  \(device["name"]?.stringValue ?? "")"))
                for app in device["apps"]?.arrayValue ?? [] {
                    print(displayText("  \(app["bundleID"]?.stringValue ?? "?")  \(app["name"]?.stringValue ?? "")"))
                }
            }
        }
    }
}

enum PluginHelp {
    static func render(_ value: NectoJSONValue) -> String {
        let plugin = value["plugin"] ?? .null
        let id = plugin["id"]?.stringValue ?? "?"
        var lines = ["\(id)  \(plugin["version"]?.stringValue ?? "")", plugin["description"]?.stringValue ?? ""]
        if let operation = value["operation"] {
            let operationID = operation["id"]?.stringValue ?? "?"
            let verb = operation["kind"] == "stream" ? "subscribe" : "send"
            lines += ["", "\(operationID)  \(operation["kind"]?.stringValue ?? "")", operation["description"]?.stringValue ?? ""]
            if operation["available"] == false { lines += ["Unavailable: \(operation["unavailableReason"]?.stringValue ?? "No matching provider")"] }
            lines += ["", "Input:"] + schemaLines(operation["inputSchema"] ?? .null)
            lines += ["", "Output:"] + schemaLines(operation["outputSchema"] ?? .null)
            if let timeout = operation["timeoutMs"]?.numberValue {
                let milliseconds = Int(exactly: timeout).map(String.init) ?? String(timeout)
                lines += ["", timeout == 0 ? "Operation timeout: none" : "Operation timeout: \(milliseconds)ms"]
            }
            let scope: String
            if value["scope"] == "desktop" { scope = "--desktop" }
            else if let device = value["target"]?["deviceID"]?.stringValue,
                    let app = value["target"]?["appBundleID"]?.stringValue {
                scope = "--device \(shellArgument(device)) --app \(shellArgument(app))"
            } else { scope = "--device <device-id> --app <bundle-id>" }
            lines += ["", "necto plugin \(verb) \(shellArgument(id)) \(shellArgument(operationID)) \(scope) --input '<json>'"]
            if verb == "subscribe" { lines += ["Use --limit <count> or --timeout 30s to bound the subscription."] }
        } else {
            lines += ["", "Operations:"]
            for operation in plugin["operations"]?.arrayValue ?? [] {
                lines += ["  \(operation["id"]?.stringValue ?? "?")  \(operation["kind"]?.stringValue ?? "")",
                          "    \(operation["description"]?.stringValue ?? "")"]
                if operation["available"] == false { lines += ["    Unavailable: \(operation["unavailableReason"]?.stringValue ?? "No matching provider")"] }
            }
            lines += ["", "Use necto plugin help \(id) <operation-id> with the same target flags for schemas."]
        }
        return displayText(lines.joined(separator: "\n"))
    }

    private static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func schemaLines(_ schema: NectoJSONValue, name: String? = nil, required: Bool = false, depth: Int = 0) -> [String] {
        let indent = String(repeating: "  ", count: depth + 1)
        guard depth < 12 else { return [indent + "… See --json for the complete schema."] }
        let type = schema["type"]?.stringValue ?? "any"
        var constraints: [String] = required ? ["required"] : []
        for key in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] {
            if let value = schema[key], let encoded = try? encodeJSON(value, pretty: false) { constraints.append("\(key)=\(encoded)") }
        }
        if let values = schema["enum"], let encoded = try? encodeJSON(values, pretty: false) { constraints.append("enum=\(encoded)") }
        if schema["additionalProperties"] == false { constraints.append("additional properties not allowed") }
        var lines = [indent + (name.map { "\($0)  " } ?? "") + type + (constraints.isEmpty ? "" : "  (\(constraints.joined(separator: ", ")))")]
        if let description = schema["description"]?.stringValue, !description.isEmpty { lines.append(indent + "  " + description) }
        let requiredFields = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        for (key, property) in (schema["properties"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines += schemaLines(property, name: key, required: requiredFields.contains(key), depth: depth + 1)
        }
        if let items = schema["items"] { lines += schemaLines(items, name: "items", depth: depth + 1) }
        return lines
    }
}

func displayText(_ text: String) -> String {
    String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
}
