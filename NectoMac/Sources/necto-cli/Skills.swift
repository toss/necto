//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import ArgumentParser
import Foundation

struct Skills: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install the Necto skill for coding agents.", subcommands: [Install.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install the bundled skill without connecting to Necto.")
        @Flag(name: .long, help: "Install in ~/.agents/skills/necto for Codex.") var codex = false
        @Flag(name: .long, help: "Install in ~/.claude/skills/necto for Claude Code.") var claude = false
        @Flag(name: .long, help: "Replace an existing, modified Necto SKILL.md.") var force = false

        func validate() throws {
            guard codex || claude else { throw ValidationError("Choose --codex, --claude, or both.") }
        }

        func run() throws {
            let manager = FileManager.default
            let home = manager.homeDirectoryForCurrentUser
            let paths = (codex ? [".agents/skills/necto"] : []) + (claude ? [".claude/skills/necto"] : [])
            let content = try Skills.content()
            let destinations = paths.map { home.appending(path: $0).appending(path: "SKILL.md") }
            for destination in destinations {
                var current = destination
                while current.path != home.path {
                    if let attributes = try? manager.attributesOfItem(atPath: current.path),
                       attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                        throw ValidationError("Refusing to install through a symbolic link: \(current.path)")
                    }
                    current.deleteLastPathComponent()
                }
                if manager.fileExists(atPath: destination.path) {
                    guard (try manager.attributesOfItem(atPath: destination.path))[.type] as? FileAttributeType == .typeRegular else {
                        throw ValidationError("Expected a regular file at \(destination.path)")
                    }
                    if try Data(contentsOf: destination) != content, !force {
                        throw ValidationError("\(destination.path) differs from the bundled skill. Use --force to replace it.")
                    }
                }
            }
            for destination in destinations {
                if (try? Data(contentsOf: destination)) == content {
                    print("Already installed: \(destination.path)")
                    continue
                }
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: destination, options: .atomic)
                print("Installed: \(destination.path)")
            }
        }
    }

    private static func content() throws -> Data {
        guard let executableURL = Bundle.main.executableURL else {
            throw ValidationError("Could not locate the Necto CLI executable.")
        }
        let executable = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let bundleName = "NectoMac_necto-cli.bundle"
        // SwiftPM puts resources beside the executable; the app ships them in Resources.
        for directory in [executable, executable.deletingLastPathComponent().appending(path: "Resources")] {
            if let bundle = Bundle(url: directory.appending(path: bundleName)),
               let url = bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/necto") {
                return try Data(contentsOf: url)
            }
        }
        throw ValidationError("The bundled Necto skill is missing. Reinstall the CLI from Necto.")
    }
}
