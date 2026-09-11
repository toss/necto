//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoCLIService
import NectoModel
import NectoTransport
import Foundation
import Testing

@testable import NectoMacService

/// A handler with canned answers, and a switch to make streams run long.
private struct StubHandler: NectoControlHandling {
    func deletePlugin(id: String) async throws -> NectoJSONValue {
        guard id == "sample" else { throw NectoBridgeError(code: .operationNotFound, message: "Unknown desktop plugin") }
        return ["deleted": true, "pluginID": .string(id)]
    }
    var streamForever = false
    var invokeForever = false
    var installForever = false
    var echoScope = false

    func installPlugin(from source: NectoPluginInstallSource) async throws -> NectoJSONValue {
        let path: String
        switch source {
        case let .localPath(value): path = value
        case let .repositoryURL(value): path = value
        }
        if path.hasSuffix("rejected.zip") {
            throw NectoBridgeError(code: .permissionDenied, message: "Installation declined in Necto.")
        }
        while installForever, !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        return ["installed": true, "pluginID": "sample", "path": .string(path)]
    }

    func targets() async -> NectoJSONValue {
        ["targets": .array([["appBundleID": "com.example.app"]])]
    }

    func plugins(app: String?, device: String?, desktop: Bool, pluginID: String?, operationID: String?) async throws -> NectoJSONValue {
        if echoScope {
            return ["app": app.map(NectoJSONValue.string) ?? .null,
                    "device": device.map(NectoJSONValue.string) ?? .null,
                    "desktop": .bool(desktop), "plugin": pluginID.map(NectoJSONValue.string) ?? .null,
                    "operation": operationID.map(NectoJSONValue.string) ?? .null]
        }
        return ["plugins": .array([["id": "sample"]])]
    }

    func invoke(
        pluginID: String,
        operationID: String,
        input: NectoJSONValue,
        app _: String?,
        device _: String?,
        desktop _: Bool
    ) async throws -> NectoJSONValue {
        guard pluginID == "sample" else {
            throw NectoBridgeError(code: .operationUnavailable, message: "No plugin '\(pluginID)'")
        }
        while invokeForever, !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        return ["echoed": input["value"] ?? .null, "operation": .string(operationID)]
    }

    func subscribe(
        pluginID _: String,
        operationID _: String,
        input _: NectoJSONValue,
        app _: String?,
        device _: String?,
        desktop _: Bool,
        onEvent: @escaping @Sendable (NectoJSONValue) -> Void
    ) async throws {
        onEvent(["tick": 1])
        onEvent(["tick": 2])
        while streamForever, !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// The client side of the tests: connect, speak the framing, remember to close.
private final class TestClient {
    let session: NectoMessageSession

    init(_ socketURL: URL) async throws {
        session = try await NectoMessageSession(stream: NectoSocketStream.connect(unixPath: socketURL.path))
    }

    deinit { session.close() }

    func receive() async throws -> NectoControlResponse {
        try await session.receive(NectoControlResponse.self)
    }
}

private func makeServer(
    _ handler: StubHandler = StubHandler()
) throws -> (server: NectoControlServer, url: URL) {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "necto-control-test-\(UUID().uuidString.prefix(8)).sock")
    let server = NectoControlServer(socketURL: url, handler: handler)
    try server.start()
    return (server, url)
}

@Suite("Control socket", .timeLimit(.minutes(1)))
struct NectoControlServerTests {
    @Test("discovery forwards ownership and operation selectors")
    func discoveryScopeRoundTrip() async throws {
        let (server, url) = try makeServer(StubHandler(echoScope: true))
        defer { server.stop() }
        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "help", kind: .plugins,
            pluginID: "shared", operationID: "read", app: "app.a", device: "one", desktop: false))
        let response = try await client.receive()
        #expect(response.value == ["app": "app.a", "device": "one", "desktop": false,
                                   "plugin": "shared", "operation": "read"])
        try await client.session.send(NectoControlRequest(id: "desktop", kind: .plugins, desktop: true))
        #expect(try await client.receive().value?["desktop"] == true)
    }
    @Test("delete returns the app result and does not succeed for an unknown ID")
    func deleteRoundTrip() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }
        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "delete", kind: .deletePlugin, pluginID: "sample"))
        #expect(try await client.receive().value?["deleted"] == true)
        try await client.session.send(NectoControlRequest(id: "unknown", kind: .deletePlugin, pluginID: "missing"))
        #expect(try await client.receive().error?.code == "OPERATION_NOT_FOUND")
    }
    @Test("repository installation reaches the app without becoming a local path")
    func repositoryInstallRoundTrip() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }
        let client = try await TestClient(url)
        let repository = "https://github.com/owner/plugins/releases/tag/v1.0.0"
        try await client.session.send(NectoControlRequest(id: "remote", kind: .installPlugin, input: ["repositoryURL": .string(repository)]))
        let response = try await client.receive()
        #expect(response.kind == .result)
        #expect(response.value?["path"]?.stringValue == repository)
    }

    @Test("the socket rejects ambiguous installation sources")
    func rejectsAmbiguousInstallSource() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }
        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "ambiguous", kind: .installPlugin,
            input: ["path": "/tmp/plugin.zip", "repositoryURL": "https://github.com/owner/plugins"]))
        #expect(try await client.receive().error?.code == "INVALID_INPUT")
    }

    @Test("installation uses the app handler and returns its completed result")
    func installRoundTrip() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }
        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "install", kind: .installPlugin, input: ["path": "/tmp/My Plugin.zip"]))
        let response = try await client.receive()
        #expect(response.kind == .result)
        #expect(response.value?["installed"] == true)
        #expect(response.value?["path"] == "/tmp/My Plugin.zip")
    }

    @Test("installation refusal and invalid input do not report success")
    func installRefusal() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }
        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "invalid", kind: .installPlugin, input: ["path": "relative.zip"]))
        #expect(try await client.receive().error?.code == "INVALID_INPUT")
        try await client.session.send(NectoControlRequest(id: "denied", kind: .installPlugin, input: ["path": "/tmp/rejected.zip"]))
        #expect(try await client.receive().error?.code == "PERMISSION_DENIED")
    }

    @Test("cancelling a pending installation ends its request")
    func cancelInstall() async throws {
        let (server, url) = try makeServer(StubHandler(installForever: true))
        defer { server.stop() }
        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "install", kind: .installPlugin, input: ["path": "/tmp/plugin.zip"]))
        try await client.session.send(NectoControlRequest(id: "install", kind: .cancel))
        #expect(try await client.receive().kind == .end)
    }

    private func temporarySocket() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "necto-control-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "control.sock")
    }

    private func boundSocket(at url: URL, listening: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            url.path.withCString { path in
                guard strlen(path) < buffer.count else { return false }
                memcpy(buffer.baseAddress!, path, strlen(path) + 1)
                return true
            }
        }
        guard copied else { Darwin.close(fd); throw POSIXError(.ENAMETOOLONG) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, !listening || listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        return fd
    }

    private func expectUsable(_ url: URL) async throws {
        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "check", kind: .targets))
        #expect(try await client.receive().id == "check")
    }

    @Test("starting twice preserves the original listener and permissions")
    func startIsIdempotent() async throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = NectoControlServer(socketURL: url, handler: StubHandler())
        defer { server.stop() }
        try server.start()
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        try server.start()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber))
        #expect((after[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await expectUsable(url)
    }

    @Test("a second server cannot replace or stop the owning server")
    func competingServer() async throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = NectoControlServer(socketURL: url, handler: StubHandler())
        let second = NectoControlServer(socketURL: url, handler: StubHandler())
        defer { first.stop(); second.stop() }
        try first.start()
        #expect(throws: NectoControlServer.Failure.self) { try second.start() }
        second.stop()
        try await expectUsable(url)
        first.stop()
        try second.start()
        first.stop()
        try await expectUsable(url)
    }

    @Test("preexisting files and symlinks are preserved", arguments: [false, true])
    func preservesForeignFiles(symlink: Bool) throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = url.appendingPathExtension("data")
        try Data("keep".utf8).write(to: target)
        if symlink {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        } else {
            try FileManager.default.copyItem(at: target, to: url)
        }
        let server = NectoControlServer(socketURL: url, handler: StubHandler())
        #expect(throws: NectoControlServer.Failure.self) { try server.start() }
        server.stop()
        #expect(try Data(contentsOf: url) == Data("keep".utf8))
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }

    @Test("an abandoned socket file can be reclaimed")
    func staleSocket() async throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Never listen: concurrent process launches can briefly inherit the descriptor before exec.
        let old = try boundSocket(at: url, listening: false)
        #expect(Darwin.close(old) == 0)
        let server = NectoControlServer(socketURL: url, handler: StubHandler())
        defer { server.stop() }
        try server.start()
        try await expectUsable(url)
    }

    @Test("a live listener without a lock file is preserved")
    func legacyListener() throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = try boundSocket(at: url, listening: true)
        defer { Darwin.close(old) }
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let server = NectoControlServer(socketURL: url, handler: StubHandler())
        #expect(throws: NectoControlServer.Failure.self) { try server.start() }
        server.stop()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber))
    }

    @Test("stop does not remove a replacement at the socket path")
    func preservesReplacement() throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = NectoControlServer(socketURL: url, handler: StubHandler())
        try server.start()
        try FileManager.default.removeItem(at: url)
        try Data("replacement".utf8).write(to: url)
        server.stop()
        #expect(try Data(contentsOf: url) == Data("replacement".utf8))
    }

    @Test("stop does not unlink a replacement socket")
    func preservesReplacementSocket() throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = NectoControlServer(socketURL: url, handler: StubHandler())
        try server.start()
        try FileManager.default.removeItem(at: url)
        let replacement = try boundSocket(at: url, listening: true)
        defer { Darwin.close(replacement) }
        server.stop()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a lock symlink cannot redirect ownership checks")
    func lockSymlink() throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = url.appendingPathExtension("data")
        try Data("keep".utf8).write(to: target)
        let lockURL = url.appendingPathExtension("lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
        let server = NectoControlServer(socketURL: url, handler: StubHandler())
        #expect(throws: NectoControlServer.Failure.self) { try server.start() }
        server.stop()
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }

    @Test("concurrent start and stop leave a restartable server")
    func concurrentLifecycle() async throws {
        let url = try temporarySocket()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = NectoControlServer(socketURL: url, handler: StubHandler())
        defer { server.stop() }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    if index.isMultiple(of: 2) { try? server.start() } else { server.stop() }
                }
            }
        }
        server.stop()
        try server.start()
        try await expectUsable(url)
    }

    @Test("answers an invoke over a real socket")
    func invokeRoundTrip() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }

        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(
            id: "r1",
            kind: .invoke,
            pluginID: "sample",
            operationID: "things.list",
            input: ["value": "hello"]
        ))

        let response = try await client.receive()
        #expect(response.id == "r1")
        #expect(response.kind == .result)
        #expect(response.value?["echoed"]?.stringValue == "hello")
        #expect(response.value?["operation"]?.stringValue == "things.list")
    }

    /// The error crosses the socket as a code and a message, so the CLI can say what
    /// the registry would have said.
    @Test("carries a refusal across, code and all")
    func errorRoundTrip() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }

        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "r1", kind: .invoke, pluginID: "nope", operationID: "x"))

        let response = try await client.receive()
        #expect(response.kind == .error)
        #expect(response.error?.code == "OPERATION_UNAVAILABLE")
    }

    @Test("streams events and then says so when the stream ends")
    func subscribeDelivers() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }

        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "s1", kind: .subscribe, pluginID: "sample", operationID: "ticks"))

        #expect(try await client.receive().value?["tick"] == .number(1))
        #expect(try await client.receive().value?["tick"] == .number(2))
        #expect(try await client.receive().kind == .end)
    }

    /// `cancel` is how ^C travels: the stream stops and answers `end` rather than
    /// leaving the terminal hanging.
    @Test("a cancel stops a running stream")
    func cancelStops() async throws {
        let (server, url) = try makeServer(StubHandler(streamForever: true))
        defer { server.stop() }

        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "s1", kind: .subscribe, pluginID: "sample", operationID: "ticks"))
        _ = try await client.receive()
        _ = try await client.receive()

        try await client.session.send(NectoControlRequest(id: "s1", kind: .cancel))
        #expect(try await client.receive().kind == .end)
    }

    @Test("a cancel stops a running invoke")
    func cancelStopsInvoke() async throws {
        let (server, url) = try makeServer(StubHandler(invokeForever: true))
        defer { server.stop() }

        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "r1", kind: .invoke, pluginID: "sample", operationID: "wait"))
        try await client.session.send(NectoControlRequest(id: "r1", kind: .cancel))

        #expect(try await client.receive().kind == .end)
    }

    /// Two requests on one connection stay two conversations: ids keep them apart even
    /// when their answers interleave.
    @Test("interleaved requests are told apart by id")
    func interleaving() async throws {
        let (server, url) = try makeServer()
        defer { server.stop() }

        let client = try await TestClient(url)
        try await client.session.send(NectoControlRequest(id: "a", kind: .targets))
        try await client.session.send(NectoControlRequest(id: "b", kind: .plugins))

        var seen: [String: NectoControlResponse.Kind] = [:]
        seen[try await client.receive().id] = .result
        seen[try await client.receive().id] = .result
        #expect(seen.keys.sorted() == ["a", "b"])
    }
}
