//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Network
import Testing
@testable import NectoMacService

@Suite("Update HTTP downloads", .timeLimit(.minutes(1)))
struct NectoUpdateDownloadTests {
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
        _ response: String, keepOpen: Bool = false, operation: @Sendable (URL) async throws -> T
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
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
