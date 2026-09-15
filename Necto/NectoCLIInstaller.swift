//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import Observation

@MainActor
@Observable
final class NectoCLIInstaller {
    private(set) var isInstalled = false
    private(set) var isInstalling = false
    private(set) var error: String?

    @ObservationIgnored private let tool: URL
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let authorize: (String) async throws -> Void

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool.path) }

    init(
        tool: URL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/necto-cli"),
        directory: URL = URL(filePath: "/usr/local/bin"),
        authorize: @escaping (String) async throws -> Void = NectoCLIInstaller.runAuthorized
    ) {
        self.tool = tool
        self.directory = directory
        self.authorize = authorize
        refresh()
    }

    func refresh() {
        guard !isInstalling else { return }
        isInstalled = (try? missingLinks().isEmpty) ?? false
    }

    func install() async {
        guard !isInstalling else { return }
        error = nil
        isInstalling = true
        defer {
            isInstalling = false
            refresh()
        }
        do {
            guard try !missingLinks().isEmpty else { return }
            try await authorize(Self.installCommand(tool: tool, directory: directory))
            guard try missingLinks().isEmpty else { throw Failure.verificationFailed }
        } catch is CancellationError {
            // Cancelling the system authentication dialog leaves the button available.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func missingLinks() throws -> [String] {
        let files = FileManager.default
        guard isAvailable else { throw Failure.missingTool }
        if let type = try itemType(at: directory.path), type != .typeDirectory {
            throw Failure.conflict(directory.path)
        }
        return try ["necto", "necto-cli"].filter { name in
            let path = directory.appending(path: name).path
            guard let type = try itemType(at: path) else { return true }
            guard type == .typeSymbolicLink || type == .typeRegular else {
                throw Failure.conflict(path)
            }
            if type == .typeSymbolicLink {
                return try files.destinationOfSymbolicLink(atPath: path) != tool.path
            }
            return true
        }
    }

    private func itemType(at path: String) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    // Recheck after authentication: the user may leave the dialog open while files change.
    static func installCommand(tool: URL, directory: URL) -> String {
        """
        set -eu
        umask 022
        tool=\(shellQuote(tool.path))
        directory=\(shellQuote(directory.path))
        [ -f "$tool" ] && [ -x "$tool" ] || exit 1
        if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }; then
            printf 'Not a directory: %s\\n' "$directory" >&2
            exit 1
        fi
        /bin/mkdir -p "$directory"
        cd -P "$directory"
        for name in necto necto-cli; do
            if [ -L "$name" ] || [ -f "$name" ] || [ ! -e "$name" ]; then
                continue
            fi
            printf 'Refusing to replace: %s/%s\\n' "$directory" "$name" >&2
            exit 1
        done
        for name in necto necto-cli; do
            if [ ! -L "$name" ] || [ "$(/usr/bin/readlink "$name")" != "$tool" ]; then
                /bin/ln -shf "$tool" "$name"
            fi
        done
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAuthorized(_ command: String) async throws {
        // Pass the command as data, not interpolated AppleScript source.
        let script = """
        on run argv
            try
                do shell script (item 1 of argv) with administrator privileges
            on error messageText number errorNumber
                if errorNumber is -128 then return "cancelled"
                error messageText number errorNumber
            end try
            return "installed"
        end run
        """
        let output = try await NectoProcessRunner.run(
            "/usr/bin/osascript", arguments: ["-e", script, command]
        )
        let result = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.exitCode == 0, result == "cancelled" { throw CancellationError() }
        guard output.exitCode == 0, result == "installed" else {
            throw NSError(domain: "NectoCLIInstaller", code: Int(output.exitCode), userInfo: [
                NSLocalizedDescriptionKey: NectoL10n.format(
                    "Could not install the CLI. %@",
                    String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ),
            ])
        }
    }

    private enum Failure: LocalizedError {
        case missingTool
        case conflict(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .missingTool: NectoL10n.text("This app does not contain the CLI.")
            case let .conflict(path): NectoL10n.format("Another item exists at %@. Move it before installing the CLI.", path)
            case .verificationFailed: NectoL10n.text("The CLI links could not be verified. Try installing again.")
            }
        }
    }
}
