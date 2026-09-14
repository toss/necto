//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Network
import Testing
@testable import NectoMacService

@Suite("Update HTTP downloads", .timeLimit(.minutes(1)))
struct NectoUpdateDownloadTests {
    @Test("reads a release tag using HEAD without following the redirect")
    func latestRelease() async throws {
        let version = try await serve(
            "HTTP/1.1 302 Found\r\nLocation: https://github.com/toss/necto/releases/tag/0.1.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            expectedMethod: "HEAD"
        ) { url in
            try await NectoAppRelease.latestVersion(at: url)
        }
        #expect(version.description == "0.1.1")
    }

    @Test("reports release lookup HTTP errors separately from downloads", arguments: [403, 404, 429, 500])
    func lookupFailure(status: Int) async throws {
        _ = try await serve(
            "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            expectedMethod: "HEAD"
        ) { url in
            await #expect(throws: NectoAppRelease.Failure.checkFailed(status)) {
                try await NectoAppRelease.latestVersion(at: url)
            }
        }
    }

    @Test("rejects a missing tag, unrelated redirect and non-release page", arguments: [
        "HTTP/1.1 302 Found\r\n",
        "HTTP/1.1 200 OK\r\n",
        "HTTP/1.1 302 Found\r\nLocation: https://github.com/login\r\n",
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/forbidden\r\n",
    ])
    func invalidLookup(response: String) async throws {
        _ = try await serve(response + "Content-Length: 0\r\nConnection: close\r\n\r\n", expectedMethod: "HEAD") { url in
            await #expect(throws: NectoAppRelease.Failure.invalidRelease) {
                try await NectoAppRelease.latestVersion(at: url)
            }
        }
    }

    @Test("cancels a stalled release lookup")
    func lookupCancellation() async throws {
        try await serve("", keepOpen: true, expectedMethod: "HEAD") { url in
            let task = Task { try await NectoAppRelease.latestVersion(at: url) }
            defer { task.cancel() }
            try await Task.sleep(for: .milliseconds(100))
            let start = ContinuousClock.now
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(start.duration(to: .now) < .seconds(1))
        }
    }

    @Test("saves a successful HTTP response")
    func response() async throws {
        let file = try await serve("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntest") { url in
            try await NectoAppRelease.download(url, maximumBytes: 64)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == Data("test".utf8))
    }

    @Test("a rejected HTTP status does not become a download")
    func httpFailure() async throws {
        _ = try await serve("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") { url in
            await #expect(throws: (any Error).self) { try await NectoAppRelease.download(url, maximumBytes: 64) }
        }
    }

    @Test("rejects empty successful downloads")
    func emptyDownload() async throws {
        _ = try await serve("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") { url in
            await #expect(throws: NectoAppRelease.Failure.invalidRelease) {
                try await NectoAppRelease.download(url, maximumBytes: 256)
            }
        }
    }

    @Test("does not follow an insecure redirect")
    func redirect() async throws {
        try await serve("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") { url in
            do {
                let file = try await NectoAppRelease.download(url, maximumBytes: 64)
                try? FileManager.default.removeItem(at: file)
                Issue.record("Redirect was accepted")
            } catch NectoAppRelease.Failure.downloadFailed(let status) {
                #expect(status == 302)
            }
        }
    }

    @Test("unknown-length oversized output is cancelled before EOF")
    func oversizedChunkedDownload() async throws {
        let bytes = String(repeating: "x", count: 65_536)
        try await serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10000\r\n\(bytes)\r\n", keepOpen: true) { url in
            let start = ContinuousClock.now
            await #expect(throws: NectoAppRelease.Failure.tooLarge) { try await NectoAppRelease.download(url, maximumBytes: 1_024) }
            #expect(start.duration(to: .now) < .seconds(3))
        }
    }

    @Test("cancelling a stalled download finishes promptly")
    func cancellation() async throws {
        try await serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", keepOpen: true) { url in
            let task = Task { try await NectoAppRelease.download(url, maximumBytes: 1_024) }
            defer { task.cancel() }
            try await Task.sleep(for: .milliseconds(100))
            let start = ContinuousClock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(start.duration(to: .now) < .seconds(1))
        }
    }

    private func serve<T: Sendable>(
        _ response: String, keepOpen: Bool = false, expectedMethod: String = "GET",
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "im.toss.necto.update-http-test")
        let ready = AsyncThrowingStream<UInt16, any Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue { ready.continuation.yield(port); ready.continuation.finish() }
            case let .failed(error): ready.continuation.finish(throwing: error)
            default: break
            }
        }
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { connection in
            accepted.continuation.yield(connection)
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 5, maximumLength: 8_192) { data, _, _, _ in
                if let data { #expect(String(decoding: data, as: UTF8.self).hasPrefix("\(expectedMethod) ")) }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    if !keepOpen { connection.cancel() }
                })
            }
        }
        listener.start(queue: queue)
        defer {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            accepted.continuation.finish()
        }
        var ports = ready.stream.makeAsyncIterator()
        let port = try #require(try await ports.next())
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/asset"))
        let result: Result<T, any Error>
        do { result = .success(try await operation(url)) }
        catch { result = .failure(error) }
        accepted.continuation.finish()
        for await connection in accepted.stream { connection.cancel() }
        return try result.get()
    }
}
