//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Darwin
import Foundation
import NectoCLIService
import NectoModel
import NectoTransport
import Testing

@Suite("CLI process interface", .timeLimit(.minutes(1)))
struct NectoCLIBlackBoxTests {
    @Test("unauthorized status survives JSON and human device discovery", arguments: [false, true])
    func unauthorizedDiscovery(json: Bool) async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            try await session.send(NectoControlResponse(id: request.id, kind: .result, value: ["targets": .array([
                ["deviceID": "sim-1", "deviceName": "Phone", "appBundleID": "protected.app", "appName": "Protected",
                 "status": "unauthorized", "reason": "missingKey"],
            ])]))
        }
        let result = try await fixture.run(["device", "list"] + (json ? ["--json"] : []))
        try await server.value
        #expect(result.status == 0)
        if json {
            let app = try result.json()["devices"]?.arrayValue?.first?["apps"]?.arrayValue?.first
            #expect(app?["status"] == "unauthorized")
            #expect(app?["reason"] == "missingKey")
        } else { #expect(result.output.contains("[unauthorized]")) }
    }

    @Test("unauthorized plugin calls return a failure, while the CLI remains available")
    func unauthorizedCall() async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            try await session.send(NectoControlResponse(id: request.id, kind: .error,
                error: .init(code: "UNAUTHORIZED", message: "Install the connection key.")))
        }
        let result = try await fixture.run(["plugin", "list", "--device", "sim-1", "--app", "protected.app", "--json"])
        try await server.value
        #expect(result.status != 0)
        #expect(result.error.contains("UNAUTHORIZED"))
        let help = try await fixture.run(["--help"])
        #expect(help.status == 0)
    }

    @Test("device discovery prints usable identifiers grouped by device")
    func deviceDiscovery() async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            #expect(request.kind == .targets)
            try await session.send(NectoControlResponse(id: request.id, kind: .result, value: [
                "targets": .array([
                    ["deviceID": "sim-1", "deviceName": "Phone", "appBundleID": "com.example.one", "appName": "One"],
                    ["deviceID": "sim-1", "deviceName": "Phone", "appBundleID": "com.example.two", "appName": "Two"],
                ]),
            ]))
        }
        let result = try await fixture.run(["device", "list", "--json"])
        try await server.value
        #expect(result.status == 0)
        #expect(result.error.isEmpty)
        let devices = try result.json()["devices"]?.arrayValue
        #expect(devices?.count == 1)
        #expect(devices?.first?["id"] == "sim-1")
        #expect(devices?.first?["apps"]?.arrayValue?.count == 2)
    }

    @Test("list and help preserve the explicit scope and progressive selectors", arguments: [
        ["plugin", "list"],
        ["plugin", "help", "sample"],
        ["plugin", "help", "sample", "records.detail"],
    ])
    func scopedDiscovery(arguments: [String]) async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            #expect(request.kind == .plugins)
            #expect(request.device == "sim-2")
            #expect(request.app == "com.example.two")
            #expect(request.pluginID == (arguments.count > 2 ? "sample" : nil))
            #expect(request.operationID == (arguments.count > 3 ? "records.detail" : nil))
            try await session.send(NectoControlResponse(id: request.id, kind: .result, value: ["selectedApp": .string(request.app ?? "")]))
        }
        let result = try await fixture.run(arguments + ["--device", "sim-2", "--app", "com.example.two", "--json"])
        try await server.value
        #expect(result.status == 0)
        #expect(try result.json()["selectedApp"] == "com.example.two")
    }

    @Test("human help exposes parameter constraints and workflow descriptions")
    func humanHelp() async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            try await session.send(NectoControlResponse(id: request.id, kind: .result, value: [
                "scope": "desktop",
                "plugin": ["id": "sample", "name": "Sample", "version": "1.0.0", "description": "Captured requests"],
                "operation": [
                    "id": "records.detail", "title": "Request detail", "kind": "once", "available": true,
                    "description": "Use an id returned by records.list as recordID.", "timeoutMs": 3000,
                    "inputSchema": ["type": "object", "required": ["recordID"], "properties": [
                        "recordID": ["type": "string", "description": "An id returned by records.list."],
                    ]],
                    "outputSchema": ["type": "object"],
                ],
            ]))
        }
        let result = try await fixture.run(["plugin", "help", "sample", "records.detail", "--desktop"])
        try await server.value
        #expect(result.status == 0)
        for expected in ["records.detail", "records.list", "recordID", "string", "required"] {
            #expect(result.output.contains(expected))
        }
    }

    @Test("missing, incomplete and conflicting scopes fail before contacting Necto", arguments: [
        ["plugin", "list"],
        ["plugin", "help", "sample", "--device", "sim-1"],
        ["plugin", "send", "sample", "read", "--app", "com.example.app"],
        ["plugin", "subscribe", "sample", "observe", "--desktop", "--device", "sim-1", "--app", "com.example.app"],
    ])
    func invalidScopes(arguments: [String]) async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let result = try await fixture.run(arguments)
        #expect(result.status != 0)
        #expect(result.output.isEmpty)
        #expect(!result.error.contains("Could not reach Necto"))
    }

    @Test("invalid inputs and stream bounds fail locally", arguments: [
        ["send", "sample", "read", "--input", "{invalid}"],
        ["send", "sample", "read", "--input", "{}", "--input-file", "missing.json"],
        ["subscribe", "sample", "observe", "--limit", "0"],
        ["subscribe", "sample", "observe", "--timeout", "-1s"],
        ["subscribe", "sample", "observe", "--timeout", "forever"],
    ])
    func invalidInputs(arguments: [String]) async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let result = try await fixture.run(["plugin"] + arguments + ["--desktop"])
        #expect(result.status != 0)
        #expect(result.output.isEmpty)
        #expect(!result.error.contains("Could not reach Necto"))
    }

    @Test("JSON input files and standard input preserve structured values", arguments: [false, true])
    func inputFile(stdin: Bool) async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let input = #"{"recordID":"r-1","nested":{"enabled":true},"values":[1,2]}"#
        let file = fixture.directory.appending(path: "request with spaces.json")
        try Data(input.utf8).write(to: file)
        let expected = try JSONDecoder().decode(NectoJSONValue.self, from: Data(input.utf8))
        let server = fixture.respond { request, session in
            #expect(request.kind == .invoke)
            #expect(request.input == expected)
            try await session.send(NectoControlResponse(id: request.id, kind: .result, value: request.input))
        }
        let result = try await fixture.run([
            "plugin", "send", "sample", "read", "--desktop", "--input-file", stdin ? "-" : file.path,
        ], input: stdin ? input : nil)
        try await server.value
        #expect(result.status == 0)
        #expect(try result.json() == expected)
    }

    @Test("remote errors and abrupt stream disconnects are failures", arguments: [false, true])
    func errorsAreNotSuccess(disconnect: Bool) async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            if !disconnect {
                try await session.send(NectoControlResponse(id: request.id, kind: .error,
                    error: .init(code: "PERMISSION_DENIED", message: "Approval was declined.")))
            }
        }
        let result = try await fixture.run(["plugin", disconnect ? "subscribe" : "send", "sample", "read", "--desktop"])
        try await server.value
        #expect(result.status != 0)
        #expect(result.output.isEmpty)
        #expect(!result.error.isEmpty)
        if !disconnect { #expect(result.error.contains("PERMISSION_DENIED")) }
    }

    @Test("stream limit prints JSONL and closes its connection")
    func streamLimit() async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            for value in 1...2 {
                try await session.send(NectoControlResponse(id: request.id, kind: .event, value: ["tick": .number(Double(value))]))
            }
            // Keep the stream open: reaching the limit must close it from the client side.
            await #expect(throws: (any Error).self) { try await session.receive(NectoControlRequest.self) }
        }
        let result = try await fixture.run(["plugin", "subscribe", "sample", "observe", "--desktop", "--limit", "2"])
        try await server.value
        #expect(result.status == 0)
        #expect(result.error.isEmpty)
        let lines = result.output.split(separator: "\n")
        let events = try lines.map { try JSONDecoder().decode(NectoJSONValue.self, from: Data($0.utf8)) }
        #expect(events == [["tick": 1], ["tick": 2]])
    }

    @Test("a quiet subscription timeout closes its connection and succeeds")
    func streamTimeout() async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { _, session in
            await #expect(throws: (any Error).self) { try await session.receive(NectoControlRequest.self) }
        }
        let result = try await fixture.run(["plugin", "subscribe", "sample", "observe", "--desktop", "--timeout", "100ms"])
        try await server.value
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test("natural stream completion succeeds without requiring a bound")
    func naturalCompletion() async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            try await session.send(NectoControlResponse(id: request.id, kind: .event, value: ["tick": 1]))
            try await session.send(NectoControlResponse(id: request.id, kind: .end))
        }
        let result = try await fixture.run(["plugin", "subscribe", "sample", "observe", "--desktop"])
        try await server.value
        #expect(result.status == 0)
        #expect(try result.json()["tick"] == 1)
    }

    @Test("SIGINT closes the active subscription and exits 130")
    func interrupt() async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let server = fixture.respond { request, session in
            try await session.send(NectoControlResponse(id: request.id, kind: .event, value: ["tick": 1]))
            await #expect(throws: (any Error).self) { try await session.receive(NectoControlRequest.self) }
        }
        let result = try await fixture.run(["plugin", "subscribe", "sample", "observe", "--desktop"], interruptAfterOutput: true)
        try await server.value
        #expect(result.status == 130)
    }

    @Test("skills install for both agents without Necto and protect user edits")
    func skillInstallation() async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let arguments = ["skills", "install", "--codex", "--claude"]
        let installed = try await fixture.run(arguments)
        #expect(installed.status == 0)
        let paths = [".agents/skills/necto/SKILL.md", ".claude/skills/necto/SKILL.md"]
        for path in paths {
            let contents = try String(contentsOf: fixture.directory.appending(path: path), encoding: .utf8)
            #expect(contents.contains("necto plugin help"))
            #expect(contents.contains("necto device list"))
        }
        let repeated = try await fixture.run(arguments)
        #expect(repeated.status == 0)
        let codex = fixture.directory.appending(path: paths[0])
        try Data("user-owned instructions\n".utf8).write(to: codex)
        let refused = try await fixture.run(["skills", "install", "--codex"])
        #expect(refused.status != 0)
        #expect(try String(contentsOf: codex, encoding: .utf8) == "user-owned instructions\n")
        let replaced = try await fixture.run(["skills", "install", "--codex", "--force"])
        #expect(replaced.status == 0)
        #expect(try String(contentsOf: codex, encoding: .utf8).contains("necto plugin help"))
    }

    @Test("skill resources resolve through PATH aliases and relocated app bundles", arguments: ["build-path", "app-direct", "app-path"])
    func relocatedSkillInstallation(mode: String) async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let builtExecutable = try CLIProcessFixture.executable()
        var executable = builtExecutable
        var resource: URL?
        if mode != "build-path" {
            let contents = fixture.directory.appending(path: "Necto.app/Contents")
            let macOS = contents.appending(path: "MacOS")
            let resources = contents.appending(path: "Resources")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            executable = macOS.appending(path: "necto-cli")
            try FileManager.default.copyItem(at: builtExecutable, to: executable)
            let bundleName = "NectoMac_necto-cli.bundle"
            let copiedResource = resources.appending(path: bundleName)
            try FileManager.default.copyItem(at: builtExecutable.deletingLastPathComponent().appending(path: bundleName), to: copiedResource)
            resource = copiedResource
        }
        var arguments = ["skills", "install", "--codex"]
        var launcher = executable
        var path: String?
        if mode.hasSuffix("path") {
            let bin = fixture.directory.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: bin.appending(path: "necto"), withDestinationURL: executable)
            launcher = URL(filePath: "/bin/bash")
            arguments = ["-c", "exec necto \"$@\"", "necto-test"] + arguments
            path = bin.path
        }
        let installed = try await fixture.run(arguments, executable: launcher, path: path)
        #expect(installed.status == 0, "\(installed.error)")
        let destination = fixture.directory.appending(path: ".agents/skills/necto/SKILL.md")
        #expect(try String(contentsOf: destination, encoding: .utf8).contains("necto plugin help"))
        if let resource {
            try FileManager.default.moveItem(at: resource, to: fixture.directory.appending(path: "removed-resource.bundle"))
            let missingResource = try await fixture.run(arguments, executable: launcher, path: path)
            #expect(missingResource.status != 0)
            #expect(missingResource.error.contains("bundled Necto skill is missing"))
        }
    }

    @Test("skill installation refuses symlink destinations even with force", arguments: [false, true])
    func skillSymlinkRefusal(fileLink: Bool) async throws {
        let fixture = try CLIProcessFixture()
        defer { fixture.close() }
        let outside = fixture.directory.appending(path: "user-owned")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let protectedFile = outside.appending(path: "SKILL.md")
        try Data("must remain unchanged".utf8).write(to: protectedFile)
        let parent = fixture.directory.appending(path: fileLink ? ".agents/skills/necto" : ".agents/skills")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: parent.appending(path: fileLink ? "SKILL.md" : "necto"),
                                                  withDestinationURL: fileLink ? protectedFile : outside)
        let result = try await fixture.run(["skills", "install", "--codex", "--force"])
        #expect(result.status != 0)
        #expect(result.error.contains("symbolic link"))
        #expect(try String(contentsOf: protectedFile, encoding: .utf8) == "must remain unchanged")
    }
}

private final class CLITestBundleMarker: NSObject {}

private final class CLIProcessFixture: @unchecked Sendable {
    let directory: URL
    private let acceptor: NectoSocketAcceptor

    init() throws {
        directory = URL(filePath: "/tmp/ncli-\(UUID().uuidString.prefix(8))")
        let socketURL = directory.appending(path: "Library/Application Support/Necto/necto.sock")
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var adopted = false
        defer { if !adopted { Darwin.close(descriptor) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketURL.path.withCString { path in
            try withUnsafeMutableBytes(of: &address.sun_path) { destination in
                guard strlen(path) < destination.count else { throw POSIXError(.ENAMETOOLONG) }
                memcpy(destination.baseAddress!, path, strlen(path) + 1)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { throw POSIXError(.EIO) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        acceptor = try NectoSocketAcceptor(descriptor: descriptor)
        adopted = true
    }

    func close() {
        acceptor.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func respond(_ handler: @escaping @Sendable (NectoControlRequest, NectoMessageSession) async throws -> Void) -> Task<Void, any Error> {
        Task {
            for try await session in acceptor.sessions {
                defer { session.close() }
                let request = try await session.receive(NectoControlRequest.self)
                try await handler(request, session)
                return
            }
        }
    }

    struct Result {
        let status: Int32
        let output: String
        let error: String
        func json() throws -> NectoJSONValue { try JSONDecoder().decode(NectoJSONValue.self, from: Data(output.utf8)) }
    }

    static func executable() throws -> URL {
        var candidate = Bundle(for: CLITestBundleMarker.self).bundleURL.resolvingSymlinksInPath()
        var executable: URL?
        for _ in 0..<5 {
            let url = candidate.appending(path: "necto-cli")
            if FileManager.default.isExecutableFile(atPath: url.path) { executable = url; break }
            candidate.deleteLastPathComponent()
        }
        return try #require(executable, "Build necto-cli before running process tests")
    }

    func run(_ arguments: [String], input: String? = nil, interruptAfterOutput: Bool = false,
             executable: URL? = nil, path: String? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = try executable ?? Self.executable()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = directory.path
        if let path { environment["PATH"] = path }
        process.environment = environment
        let outputURL = directory.appending(path: "stdout-\(UUID().uuidString)")
        let errorURL = directory.appending(path: "stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        process.standardOutput = output
        process.standardError = error
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        if let input { try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try pipe.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var interrupted = false
        while process.isRunning, ContinuousClock.now < deadline {
            if interruptAfterOutput, !interrupted, (try Data(contentsOf: outputURL)).count > 0 {
                kill(process.processIdentifier, SIGINT)
                interrupted = true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            Issue.record("CLI did not finish within ten seconds: \(arguments)")
            while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        }
        return Result(status: process.terminationStatus,
            output: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            error: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
    }
}
