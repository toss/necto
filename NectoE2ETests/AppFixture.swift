//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import Darwin
import Foundation
import Testing

@MainActor
final class AppFixture {
    static let exampleID = "im.toss.necto.e2e.example"
    private let products: URL
    private let executable: URL
    private let home: URL
    private let logs: URL
    private var simulator: String?
    private var commands: [Command] = []

    init() throws {
        // Resolve beside the test bundle so CI artifacts can move between runners.
        products = Bundle(for: AppFixture.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        executable = products.appending(path: "Debug/necto-cli")
        logs = products.deletingLastPathComponent().appending(path: "Logs")
            .appending(path: UUID().uuidString)
        // Keep the Unix socket path below sockaddr_un's limit, including on CI runners.
        home = URL(filePath: "/tmp/necto-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        print("E2E command logs: \(logs.path)")
    }

    func start() async throws {
        let running = NSWorkspace.shared.runningApplications.filter { $0.executableURL?.lastPathComponent == "Necto" }
        try #require(running.isEmpty, "Quit other Necto instances before E2E; they share the SDK's loopback ports.")
        let host = products.appending(path: "Debug/Necto.app")
        let example = products.appending(path: "Debug-iphonesimulator/ExampleApp.app")
        try #require(Bundle(url: host)?.bundleIdentifier == "im.toss.necto.e2e.host", "Build isolated apps with script/test e2e")
        try #require(Bundle(url: example)?.bundleIdentifier == Self.exampleID)
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))

        let available = try await run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"])
        let devices = try #require(available.json()["devices"] as? [String: [[String: Any]]])
        let phone = try #require(Self.selectSimulator(devices), "No available iPhone 17 Pro simulator. Add one in Xcode before running E2E.")
        let id = try #require(phone["udid"] as? String)
        try #require(UUID(uuidString: id) != nil)
        print("E2E simulator: iPhone 17 Pro (\(id))")
        // First-boot services can still delay installation after bootstatus completes.
        // Share one preparation deadline; the connection test does not need Simulator.app.
        let preparationDeadline = ContinuousClock.now + .seconds(600)
        let preparationStart = commands.count
        do {
            _ = try await run("/usr/bin/xcrun", ["simctl", "bootstatus", id, "-b"], deadline: preparationDeadline)
            print("E2E: simulator booted")
            simulator = id
            _ = try await run("/usr/bin/xcrun", ["simctl", "install", id, example.path], deadline: preparationDeadline)
            print("E2E: Example installed")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure(message: """
                Simulator preparation failed: \(error)
                Preparation command logs:
                \(commands.dropFirst(preparationStart).map { $0.logTail() }.joined(separator: "\n"))
                """)
        }
        let hostCommand = try launch(host.appending(path: "Contents/MacOS/Necto"), [], isolated: true)
        try await waitForControlSocket(hostCommand)
        try await launchExample()
    }

    // A cold AppKit launch on CI can outlast the operation-level deadline.
    func waitForControlSocket(_ host: Command, timeout: Duration = .seconds(120)) async throws {
        do {
            try await wait("GUI control socket", timeout: timeout) {
                guard host.process.isRunning else {
                    throw Failure(message: "Necto exited before its control socket was ready (status \(host.process.terminationStatus)).")
                }
                let result = try await self.cli(["device", "list", "--json"], scoped: false)
                return result.status == 0
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure(message: """
                \(error)
                Host logs:
                \(host.logTail())
                Last command logs:
                \(commands.last?.logTail() ?? "No commands ran.")
                """)
        }
    }

    static func selectSimulator(_ devices: [String: [[String: Any]]]) -> [String: Any]? {
        devices.keys.filter {
            $0.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-")
        }.sorted {
            $0.compare($1, options: .numeric) == .orderedDescending
        }.flatMap { devices[$0] ?? [] }.first {
            $0["name"] as? String == "iPhone 17 Pro"
        }
    }

    func launchExample() async throws {
        _ = try await run("/usr/bin/xcrun", ["simctl", "launch", try #require(simulator), Self.exampleID], timeout: .seconds(120))
    }

    func terminateExample() async throws {
        _ = try await run("/usr/bin/xcrun", ["simctl", "terminate", try #require(simulator), Self.exampleID])
    }

    func waitForDevice(connected: Bool) async throws {
        try await wait(connected ? "Example connection" : "Example disconnection") {
            let result = try await self.cli(["device", "list", "--json"], scoped: false)
            try result.requireSuccess()
            let devices = try #require(result.json()["devices"] as? [[String: Any]])
            let device = devices.first { $0["id"] as? String == self.simulator }
            let apps = device?["apps"] as? [[String: Any]] ?? []
            return apps.contains { $0["bundleID"] as? String == Self.exampleID } == connected
        }
    }

    func waitForPlugins() async throws {
        try await waitForDevice(connected: true)
        try await wait("device plugin registration") {
            let result = try await self.json(["plugin", "list", "--json"])
            #expect(result["scope"] as? String == "device")
            let target = try #require(result["target"] as? [String: Any])
            #expect(target["deviceID"] as? String == self.simulator)
            #expect(target["appBundleID"] as? String == Self.exampleID)
            let plugins = try #require(result["plugins"] as? [[String: Any]])
            let ids = Set(plugins.compactMap { $0["id"] as? String })
            return ids.isSuperset(of: ["preferences", "performance-monitor"])
        }
    }

    func json(_ arguments: [String]) async throws -> [String: Any] {
        let result = try await cli(arguments)
        try result.requireSuccess()
        return try result.json()
    }

    func cli(_ arguments: [String], scoped: Bool = true) async throws -> Result {
        try await finish(launch(executable, arguments + (scoped ? scope : []), isolated: true))
    }

    func subscribe(limit: Int? = nil) throws -> Command {
        try launch(executable, [
            "plugin", "subscribe", "performance-monitor", "performance.observe", "--input", #"{"interval":0.2}"#,
        ] + scope + (limit.map { ["--limit", String($0)] } ?? []), isolated: true)
    }

    private var scope: [String] { ["--device", simulator ?? "", "--app", Self.exampleID] }

    func waitForOutput(_ command: Command) async throws {
        try await wait("first stream event") {
            if !(try Data(contentsOf: command.output)).isEmpty { return true }
            if !command.process.isRunning {
                throw Failure(message: "Stream exited before its first event: \(try command.result().error)")
            }
            return false
        }
    }

    private func wait(_ description: String, timeout: Duration = .seconds(30), until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(try await condition()) {
            guard ContinuousClock.now < deadline else {
                throw Failure(message: "Timed out waiting for \(description). Logs: \(logs.path)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("E2E: \(description)")
    }

    struct Result {
        let status: Int32
        let output: String
        let error: String

        func requireSuccess() throws {
            try #require(status == 0, "Command exited \(status): \(error)")
            #expect(error.isEmpty)
        }

        func json() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        }
    }

    struct Command {
        let process: Process
        let output: URL
        let error: URL

        func result() throws -> Result {
            Result(status: process.terminationStatus,
                   output: String(decoding: try Data(contentsOf: output), as: UTF8.self),
                   error: String(decoding: try Data(contentsOf: error), as: UTF8.self))
        }

        func logTail() -> String {
            [output, error].map { url in
                do {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let size = try file.seekToEnd()
                    try file.seek(toOffset: size > 8192 ? size - 8192 : 0)
                    let text = String(decoding: try file.read(upToCount: 8192) ?? Data(), as: UTF8.self)
                    let lines = text.split(separator: "\n").suffix(10).joined(separator: "\n")
                    return "\(url.lastPathComponent) (last 10 lines, up to 8 KiB):\n\(lines)"
                } catch {
                    return "Could not read \(url.path): \(error)"
                }
            }.joined(separator: "\n")
        }
    }

    func launch(_ url: URL, _ arguments: [String], isolated: Bool = false) throws -> Command {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if isolated {
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = home.path
            process.environment = environment
        }
        let name = "\(commands.count)-\(url.lastPathComponent)"
        let output = logs.appending(path: "\(name).stdout")
        let error = logs.appending(path: "\(name).stderr")
        try Data().write(to: output)
        try Data().write(to: error)
        try Data(arguments.joined(separator: "\n").utf8).write(to: logs.appending(path: "\(name).args"))
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: error)
        defer { try? stdout.close(); try? stderr.close() }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let command = Command(process: process, output: output, error: error)
        commands.append(command)
        return command
    }

    func finish(_ command: Command, timeout: Duration = .seconds(30)) async throws -> Result {
        try await finish(command, deadline: ContinuousClock.now + timeout)
    }

    func finish(_ command: Command, deadline: ContinuousClock.Instant) async throws -> Result {
        while command.process.isRunning {
            if ContinuousClock.now >= deadline {
                kill(command.process.processIdentifier, SIGKILL)
                throw Failure(message: """
                    Command timed out: \(command.process.arguments ?? []). Logs: \(logs.path)
                    \(command.logTail())
                    """)
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch {
                if command.process.isRunning { kill(command.process.processIdentifier, SIGKILL) }
                throw error
            }
        }
        return try command.result()
    }

    private func run(_ path: String, _ arguments: [String], timeout: Duration = .seconds(30)) async throws -> Result {
        try await run(path, arguments, deadline: ContinuousClock.now + timeout)
    }

    func run(_ path: String, _ arguments: [String], deadline: ContinuousClock.Instant) async throws -> Result {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw Failure(message: "Command deadline expired before launch: \(path) \(arguments). Logs: \(logs.path)")
        }
        let result = try await finish(launch(URL(filePath: path), arguments), deadline: deadline)
        try #require(result.status == 0, "\(path) \(arguments): \(result.error)")
        return result
    }

    func close() async {
        // Cleanup must finish even if the test was cancelled.
        await Task { await cleanUp() }.value
    }

    private func cleanUp() async {
        for command in commands where command.process.isRunning {
            command.process.terminate()
            _ = try? await finish(command, timeout: .seconds(5))
        }
        if let simulator {
            do { _ = try await run("/usr/bin/xcrun", ["simctl", "uninstall", simulator, Self.exampleID], timeout: .seconds(120)) }
            catch { Issue.record(error) }
        }
        do { try FileManager.default.removeItem(at: home) }
        catch { Issue.record(error) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
