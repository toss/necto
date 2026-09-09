//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import ArgumentParser
import NectoCLIService
import NectoModel
import Foundation
import Testing

@testable import necto_cli

@Suite("necto-cli commands")
struct NectoCLICommandTests {
    @Test("delete identifies an installed plugin without accepting filesystem paths")
    func buildsDeleteRequest() throws {
        for arguments in [["delete", "com.example.plugin", "--json"], ["plugin", "delete", "com.example.plugin"]] {
            let parsed = try NectoCLI.parseAsRoot(arguments)
            let command = try #require(parsed as? Plugin.Delete)
            let request = try command.request()
            #expect(request.kind == .deletePlugin)
            #expect(request.pluginID == "com.example.plugin")
            #expect(request.input == nil)
        }
        let parsed = try NectoCLI.parseAsRoot(["delete", "../plugin"])
        let command = try #require(parsed as? Plugin.Delete)
        #expect(throws: (any Error).self) { try command.request() }
    }
    @Test("root install defaults to remote and accepts an explicit remote flag")
    func defaultsInstallToRemote() throws {
        for arguments in [["install", "owner/plugins"], ["install", "owner/plugins", "--remote"]] {
            let parsed = try NectoCLI.parseAsRoot(arguments)
            let command = try #require(parsed as? Plugin.Install)
            #expect(try command.request().input?["repositoryURL"] == "https://github.com/owner/plugins")
        }
    }

    @Test("root install requires local mode for files and rejects conflicting modes")
    func installModeIsExplicit() throws {
        let parsed = try NectoCLI.parseAsRoot(["install", "./dist", "--local"])
        let command = try #require(parsed as? Plugin.Install)
        #expect(try command.request().input?["path"]?.stringValue == URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "dist").path)
        for arguments in [["install", "./dist"], ["install", "owner/plugins", "--local", "--remote"],
                          ["install", "https://github.com/owner/plugins", "--local"]] {
            #expect(throws: (any Error).self) {
                let parsed = try NectoCLI.parseAsRoot(arguments)
                let command = try #require(parsed as? Plugin.Install)
                _ = try command.request()
            }
        }
    }

    @Test("repository URLs stay remote, including explicit releases", arguments: [
        "https://github.com/owner/plugins",
        "https://github.com/owner/plugins/releases/tag/v1.2.0",
        "https://github.example.com/team/plugins",
    ])
    func buildsRepositoryInstallRequest(source: String) throws {
        let parsed = try NectoCLI.parseAsRoot(["plugin", "install", source, "--json"])
        let command = try #require(parsed as? Plugin.Install)
        let request = try command.request()
        #expect(request.input?["repositoryURL"]?.stringValue == source)
        #expect(request.input?["path"] == nil)
    }

    @Test("repository input rejects insecure or credential-bearing URLs", arguments: [
        "http://github.com/owner/plugins", "ssh://github.com/owner/plugins",
        "https://user:secret@github.com/owner/plugins", "https://github.com/owner/plugins?token=secret",
    ])
    func rejectsUnsafeRepositoryInput(source: String) throws {
        let parsed = try NectoCLI.parseAsRoot(["plugin", "install", source])
        let command = try #require(parsed as? Plugin.Install)
        #expect(throws: (any Error).self) { try command.request() }
    }

    @Test("install sends an absolute local path and preserves spaces")
    func buildsInstallRequest() throws {
        let parsed = try NectoCLI.parseAsRoot(["plugin", "install", "plugins/My Plugin/dist", "--local", "--json"])
        let command = try #require(parsed as? Plugin.Install)
        let request = try command.request()
        #expect(command.json)
        #expect(request.kind == .installPlugin)
        #expect(request.pluginID == nil)
        #expect(request.input?["path"]?.stringValue == URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "plugins/My Plugin/dist").standardizedFileURL.path)
    }

    @Test("install accepts an absolute zip path and rejects an empty path")
    func validatesInstallPath() throws {
        let parsed = try NectoCLI.parseAsRoot(["plugin", "install", "/tmp/plugin.zip", "--local"])
        let command = try #require(parsed as? Plugin.Install)
        #expect(try command.request().input?["path"] == "/tmp/plugin.zip")
        let empty = try NectoCLI.parseAsRoot(["plugin", "install", ""])
        let emptyCommand = try #require(empty as? Plugin.Install)
        #expect(throws: ValidationError.self) { try emptyCommand.request() }
    }

    @Test("invoke preserves the discovered operation and target", arguments: [
        ("files", "files.write", #"{"root":"documents","path":"note.txt","content":"hello"}"#),
        ("performance-monitor", "performance.snapshot", "{}"),
        ("view-inspector", "views.highlight", #"{"viewID":"view-1"}"#),
        ("view-inspector", "views.tapAt", #"{"x":196.5,"y":426}"#),
        ("view-inspector", "views.inputText", #"{"viewID":"field-1","text":"hello","replace":true}"#),
        ("encrypted-network", "encrypted-network.detail", #"{"recordID":"r1","decrypt":true}"#),
        ("toss-user-defaults", "toss-defaults.set", #"{"path":"feature.enabled","value":false}"#),
    ])
    func buildsInvokeRequest(plugin: String, operation: String, input: String) throws {
        let parsed = try NectoCLI.parseAsRoot([
            "plugin", "invoke", plugin, operation,
            "--input", input,
            "--app", "com.example.app",
            "--device", "simulator-1",
        ])
        let command = try #require(parsed as? Plugin.Invoke)
        let request = try command.request()

        #expect(request.kind == .invoke)
        #expect(request.pluginID == plugin)
        #expect(request.operationID == operation)
        #expect(request.app == "com.example.app")
        #expect(request.device == "simulator-1")
        let expected = try JSONDecoder().decode(NectoJSONValue.self, from: Data(input.utf8))
        #expect(request.input == expected)
    }

    @Test("an omitted input becomes an empty object")
    func defaultsInput() throws {
        let parsed = try NectoCLI.parseAsRoot(["plugin", "invoke", "files", "files.roots"])
        let command = try #require(parsed as? Plugin.Invoke)
        #expect(try command.request().input == .object([:]))
    }

    @Test("invalid JSON is rejected before opening the control socket")
    func rejectsInvalidInput() throws {
        let parsed = try NectoCLI.parseAsRoot([
            "plugin", "invoke", "files", "files.write", "--input", "{not-json}",
        ])
        let command = try #require(parsed as? Plugin.Invoke)
        #expect(throws: ValidationError.self) { try command.request() }
    }

    @Test("subscribe builds a stream request")
    func buildsSubscribeRequest() throws {
        let parsed = try NectoCLI.parseAsRoot([
            "plugin", "subscribe", "performance-monitor", "performance.observe", "--input", #"{"interval":0.5}"#,
        ])
        let command = try #require(parsed as? Plugin.Subscribe)
        let request = try command.request()

        #expect(request.kind == .subscribe)
        #expect(request.pluginID == "performance-monitor")
        #expect(request.operationID == "performance.observe")
        #expect(request.input?["interval"] == .number(0.5))
    }

    @Test("shell run uses the dedicated CLI principal and exact command")
    func buildsShellRequest() throws {
        let parsed = try NectoCLI.parseAsRoot(["shell", "run", "git status --short"])
        let command = try #require(parsed as? Shell.Run)
        let request = command.request()

        #expect(request.kind == .invoke)
        #expect(request.pluginID == NectoCLIShell.pluginID)
        #expect(request.operationID == NectoCLIShell.operationID)
        #expect(request.input?["command"] == "git status --short")
    }
}
