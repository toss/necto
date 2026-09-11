//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import ArgumentParser
import NectoCLIService
import NectoModel
import Foundation

@main
struct NectoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "necto",
        abstract: "Control a running Necto from the terminal.",
        discussion: """
        Use device list to find connected apps, then plugin list and plugin help with
        --device and --app. Use --desktop for installed desktop plugins. send and
        subscribe use the same schemas, registry and permissions as web panels.
        """,
        subcommands: [Plugin.Install.self, Plugin.Delete.self, Device.self, Targets.self, Plugin.self, Shell.self, Skills.self, FinishUpdate.self]
    )
}

struct FinishUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_finish-update",
        abstract: "Complete an update after the running Necto exits.",
        shouldDisplay: false
    )

    @Argument var oldPID: Int32
    @Argument var target: String
    @Argument var workspace: String

    func run() async throws {
        try UpdateFinisher.finish(
            oldPID: oldPID,
            target: URL(filePath: target, directoryHint: .isDirectory),
            workspace: URL(filePath: workspace, directoryHint: .isDirectory)
        )
    }
}

struct Shell: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run shell commands through the permissions of the running Necto.",
        subcommands: [Run.self]
    )

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run one Bash command. Configure access in Necto Settings first."
        )

        @Argument(help: "The exact Bash command to run.")
        var command: String

        func request() -> NectoControlRequest {
            .init(
                kind: .invoke,
                pluginID: NectoCLIShell.pluginID,
                operationID: NectoCLIShell.operationID,
                input: ["command": .string(command)],
                desktop: true
            )
        }

        func run() async throws {
            let value = try await Client().request(request())
            if let stdout = value["stdout"]?.stringValue, !stdout.isEmpty {
                print(stdout, terminator: "")
            }
            if let stderr = value["stderr"]?.stringValue, !stderr.isEmpty {
                FileHandle.standardError.write(Data(stderr.utf8))
            }
            let status = Int32(value["exitCode"]?.numberValue ?? 0)
            if status != 0 { throw ExitCode(status) }
        }
    }
}

// MARK: - Commands

struct Targets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List connected apps and devices.")

    @Flag(name: .long, help: "Print JSON for machines instead of a table.")
    var json = false

    func run() async throws {
        let value = try await Client().request(.init(kind: .targets))
        if json {
            print(try encodeJSON(value))
            return
        }

        let targets = value["targets"]?.arrayValue ?? []
        guard !targets.isEmpty else {
            print("No app is connected.")
            return
        }
        for target in targets {
            let bundle = target["appBundleID"]?.stringValue ?? "?"
            let device = target["deviceName"]?.stringValue ?? target["deviceID"]?.stringValue ?? "?"
            print("\(bundle)  ·  \(device)")
        }
    }
}

struct Plugin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Discover and call what the running Necto has installed, and package a new one.",
        subcommands: [List.self, Help.self, Install.self, Delete.self, Schema.self, Invoke.self, Subscribe.self, Pack.self]
    )

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move an installed desktop plugin to Trash and revoke its registration.")
        @Argument(help: "The plugin ID shown by plugin list.") var plugin: String
        @Flag(name: .long, help: "Print the completed deletion result as JSON.") var json = false

        func request() throws -> NectoControlRequest {
            let deletion = try NectoPluginDeletion(pluginID: plugin)
            return .init(kind: .deletePlugin, pluginID: deletion.pluginID)
        }

        func run() async throws {
            let result = try await Client().request(request())
            guard result["deleted"]?.boolValue == true else { throw ValidationError("Necto did not confirm deletion.") }
            if json { print(try encodeJSON(result)) }
            else { print("Deleted \(plugin)") }
        }
    }

    struct Install: AsyncParsableCommand {
        enum Mode: String, EnumerableFlag {
            case local
            case remote
        }

        static let configuration = CommandConfiguration(
            abstract: "Install a desktop plugin from a folder, ZIP or GitHub repository URL.",
            discussion: "Remote is the default. Use --local for a built folder or ZIP. Necto validates the source, asks for approval, and returns the completed installation result."
        )

        @Argument(help: "A repository URL or owner/repo; with --local, a built folder or ZIP.")
        var source: String

        @Flag(exclusivity: .exclusive, help: "Source location. Defaults to --remote.")
        var mode: Mode = .remote

        @Flag(name: .long, help: "Print the completed installation result as JSON.")
        var json = false

        func request() throws -> NectoControlRequest {
            guard !source.isEmpty else { throw ValidationError("A plugin folder, ZIP or GitHub repository URL is required.") }
            return .init(kind: .installPlugin, input: try NectoPluginInstallSource(argument: source, local: mode == .local).input)
        }

        func run() async throws {
            let request = try request()
            FileHandle.standardError.write(Data("Requesting installation. Review its approval in Necto when prompted…\n".utf8))
            let value: NectoJSONValue
            do {
                value = try await Client().request(request)
            } catch Client.Failure.protocolError {
                throw ValidationError("Necto could not complete the installation request. Update the running app if it does not support plugin install.")
            }
            guard value["installed"]?.boolValue == true else {
                throw ValidationError("Necto did not confirm installation.")
            }
            if json { print(try encodeJSON(value)); return }
            print("Installed \(value["pluginID"]?.stringValue ?? "plugin") \(value["version"]?.stringValue ?? "")")
            if value["enabled"]?.boolValue == false { print("The plugin is still disabled in Necto Settings.") }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List plugins belonging to an explicit app or the desktop.")
        @OptionGroup var target: TargetOptions
        @Flag(name: .long, help: "Print JSON.") var json = false

        func request() throws -> NectoControlRequest {
            try target.validate()
            return .init(kind: .plugins, app: target.app, device: target.device, desktop: target.desktop)
        }

        func run() async throws {
            let value = try await Client().request(try request())
            if json { print(try encodeJSON(value)); return }
            let plugins = value["plugins"]?.arrayValue ?? []
            guard !plugins.isEmpty else { print("No plugins in this scope."); return }
            for plugin in plugins {
                print(displayText("\(plugin["id"]?.stringValue ?? "?")  \(plugin["version"]?.stringValue ?? "")"))
                print(displayText("  \(plugin["description"]?.stringValue ?? "")"))
            }
        }
    }

    struct Help: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "help", abstract: "Read a plugin's descriptions and operation schemas.")
        @Argument(help: "Plugin ID from plugin list.") var plugin: String
        @Argument(help: "Operation ID. Omit to list the plugin's operations.") var operation: String?
        @OptionGroup var target: TargetOptions
        @Flag(name: .long, help: "Print structured descriptions and schemas as JSON.") var json = false

        func request() throws -> NectoControlRequest {
            try target.validate()
            return .init(kind: .plugins, pluginID: plugin, operationID: operation,
                         app: target.app, device: target.device, desktop: target.desktop)
        }

        func run() async throws {
            let value = try await Client().request(try request())
            if json { print(try encodeJSON(value)); return }
            print(PluginHelp.render(value))
        }
    }

    struct Schema: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one operation's input and output schemas.")
        @Argument var plugin: String
        @Argument var operation: String
        @OptionGroup var target: TargetOptions

        func run() async throws {
            try target.validate()
            let value = try await Client().request(.init(
                kind: .plugins, pluginID: plugin, operationID: operation,
                app: target.app, device: target.device, desktop: target.desktop
            ))
            guard let operation = value["operation"] else { throw Client.Failure.protocolError }
            print(try encodeJSON(["input": operation["inputSchema"] ?? .null,
                                  "output": operation["outputSchema"] ?? .null]))
        }
    }

    struct Invoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "send", abstract: "Call an operation that answers once (kind: once).",
            aliases: ["invoke"]
        )
        @Argument(help: "Plugin ID.") var plugin: String
        @Argument(help: "Operation ID from plugin help.") var operation: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var payload: InputOptions

        func request() throws -> NectoControlRequest {
            try target.validate()
            return .init(kind: .invoke, pluginID: plugin, operationID: operation, input: try payload.value(),
                         app: target.app, device: target.device, desktop: target.desktop)
        }

        func run() async throws {
            let value = try await Client().request(try request())
            print(try encodeJSON(value))
        }
    }

    struct Subscribe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Subscribe to a stream. Prints JSON Lines until completion, a bound, or Ctrl+C."
        )
        @Argument(help: "Plugin ID.") var plugin: String
        @Argument(help: "Operation ID from plugin help.") var operation: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var payload: InputOptions
        @Option(name: .long, help: "Stop successfully after this many events.") var limit: Int?
        @Option(name: .long, help: "Stop successfully after a duration, for example 30s or 500ms.") var timeout: String?

        func request() throws -> NectoControlRequest {
            try target.validate()
            if let limit, limit <= 0 { throw ValidationError("--limit must be greater than zero.") }
            _ = try duration()
            return .init(kind: .subscribe, pluginID: plugin, operationID: operation, input: try payload.value(),
                         app: target.app, device: target.device, desktop: target.desktop)
        }

        func duration() throws -> Duration? {
            guard let timeout else { return nil }
            let multiplier: Double
            let number: Substring
            if timeout.hasSuffix("ms") { multiplier = 0.001; number = timeout.dropLast(2) }
            else if timeout.hasSuffix("s") { multiplier = 1; number = timeout.dropLast() }
            else { throw ValidationError("--timeout requires a unit: 30s or 500ms.") }
            guard let value = Double(number), value.isFinite,
                  value * multiplier > 0, value * multiplier < Double(Int64.max) else {
                throw ValidationError("--timeout must be a positive, representable duration in seconds or milliseconds.")
            }
            let duration = Duration.seconds(value * multiplier)
            guard duration > .zero else {
                throw ValidationError("--timeout is too small to represent.")
            }
            return duration
        }

        func run() async throws {
            try await Client().stream(try request(), limit: limit, timeout: try duration()) { event in
                if let line = try? encodeJSON(event, pretty: false) {
                    FileHandle.standardOutput.write(Data((line + "\n").utf8))
                }
            }
        }
    }
}


/// Packaging is the one thing here that does not go through the running app.
///
/// It reads a folder and writes an archive, and the only reason it lives in this
/// tool rather than a script is the check: the manifest is decoded and validated by
/// the same type the app installs with, so a folder that packs is a folder that
/// installs. A second validator written in another language would drift from this
/// one, and the drift would only show up on someone else's Mac.
struct Pack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a built plugin folder and zip it for a release."
    )

    @Argument(help: "The built folder — the one with manifest.json in it, usually dist.")
    var directory: String

    @Option(name: .shortAndLong, help: "Where to write the archive. Defaults to the working directory.")
    var output: String?

    @Flag(name: .long, help: "Leave out the suggested next command.")
    var quiet = false

    func run() async throws {
        let root = URL(filePath: directory).standardizedFileURL
        let manifest = try Self.manifest(in: root)

        let base = "\(manifest.id)-\(manifest.version)"
        let destination = URL(filePath: output ?? FileManager.default.currentDirectoryPath).standardizedFileURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let archivePath = destination.appending(path: "\(base).zip")
        try? FileManager.default.removeItem(at: archivePath)
        try Self.zip(root, into: archivePath)

        // The manifest rides alongside the archive so Necto can say what a release
        // offers without downloading every plugin in it first.
        let manifestPath = destination.appending(path: "\(base).manifest.json")
        try Data(contentsOf: root.appending(path: "manifest.json")).write(to: manifestPath)

        print("\(manifest.name) \(manifest.version) — \(manifest.id)")
        for operation in manifest.operations {
            print("  binds \(operation.binding.name)")
        }
        print("")
        print("  \(archivePath.lastPathComponent)")
        print("  \(manifestPath.lastPathComponent)")

        // The next step is only news to someone doing this by hand. A script that
        // packages several plugins is going to publish them together.
        if !quiet {
            print("")
            print("Next:")
            print("  gh release create <tag> \(archivePath.lastPathComponent) \(manifestPath.lastPathComponent)")
        }
    }

    private static func manifest(in root: URL) throws -> NectoPluginManifest {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("There is no folder at \(root.path).")
        }

        let archive: NectoPanelArchive
        do {
            archive = try NectoPanelArchive.read(directory: root)
        } catch {
            throw ValidationError("\(root.path) could not be read: \(error)")
        }

        guard let data = archive.files.first(where: { $0.path == "manifest.json" })?.data else {
            throw ValidationError("No manifest.json in \(root.path). Point this at the built folder, not the sources.")
        }

        let manifest: NectoPluginManifest
        do {
            manifest = try JSONDecoder().decode(NectoPluginManifest.self, from: data)
        } catch {
            throw ValidationError("manifest.json could not be read: \(error)")
        }

        do {
            try manifest.validate()
        } catch {
            throw ValidationError("\(error)")
        }

        // Only the Mac answers a desktop plugin, and that is what lets one be installed
        // from anywhere. A panel that binds the app's bridges is the app's to carry, so
        // packaging it would produce an archive nobody can install.
        if let bound = manifest.operations.first(where: { $0.binding.type == .device }) {
            throw ValidationError("""
            This plugin binds '\(bound.binding.name)', which a connected app answers. \
            A plugin that needs the app rides in the app: add its Swift package there.
            """)
        }

        return manifest
    }

    /// `ditto` for the same reason the app unpacks with it: it is on every Mac and it
    /// writes the archive Finder and GitHub both read.
    ///
    /// Without `--norsrc --noextattr` it also writes a `__MACOSX` entry for every file,
    /// carrying this Mac's extended attributes into a public artifact. The installer
    /// skips them, but nobody should have to receive them.
    private static func zip(_ directory: URL, into archive: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", directory.path, archive.path]

        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ValidationError("Could not write the archive: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

// MARK: - Helpers

func parseInput(_ raw: String?) throws -> NectoJSONValue {
    guard let raw else { return .object([:]) }
    do {
        return try JSONDecoder().decode(NectoJSONValue.self, from: Data(raw.utf8))
    } catch {
        throw ValidationError("--input must contain valid JSON.")
    }
}

func encodeJSON(_ value: some Encodable, pretty: Bool = true) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
}
