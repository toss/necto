//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing
@testable import NectoTransport

private func socketPair() throws -> (NectoSocketStream, NectoSocketStream) {
    var descriptors: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    var size: Int32 = 4096
    setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    return (NectoSocketStream(descriptor: descriptors[0]), NectoSocketStream(descriptor: descriptors[1]))
}

@Suite("Asynchronous socket I/O", .timeLimit(.minutes(1)))
struct NectoSocketConcurrencyTests {
    @Test("acceptor rejects a descriptor it cannot make nonblocking")
    func invalidAcceptorDescriptor() {
        #expect(throws: POSIXError.self) { try NectoSocketAcceptor(descriptor: -1) }
    }

    @Test("concurrent large frames never interleave", arguments: 0..<8)
    func concurrentFrames(_: Int) async throws {
        let (outgoing, incoming) = try socketPair()
        let writer = NectoMessageSession(stream: outgoing)
        let reader = NectoMessageSession(stream: incoming)
        defer { writer.close(); reader.close() }

        try await writer.handshake(timeout: .seconds(10)) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    group.addTask {
                        let payload = Data(repeating: UInt8(index), count: 512 * 1024)
                        for _ in 0..<10 { try await writer.send(payload) }
                    }
                }
                group.addTask {
                    var counts = [Int](repeating: 0, count: 4)
                    for _ in 0..<40 {
                        let payload = try await reader.receive()
                        try #require(payload.count == 512 * 1024)
                        let value = try #require(payload.first)
                        try #require(value < 4)
                        #expect(payload == Data(repeating: value, count: payload.count))
                        counts[Int(value)] += 1
                    }
                    #expect(counts == [10, 10, 10, 10])
                }
                try await group.waitForAll()
            }
        }
    }

    @Test("EOF in a partial header or body fails", arguments: [
        Data([0, 0]), Data([0, 0, 0, 8, 1, 2, 3]),
    ])
    func partialEOF(bytes: Data) async throws {
        let (writer, incoming) = try socketPair()
        let reader = NectoMessageSession(stream: incoming)
        defer { writer.close(); reader.close() }
        try await writer.write(bytes)
        writer.close()
        await #expect(throws: NectoSocketStream.Failure.self) { try await reader.receive() }
    }

    @Test("an empty frame does not consume the next frame")
    func emptyFrame() async throws {
        let (outgoing, incoming) = try socketPair()
        let writer = NectoMessageSession(stream: outgoing)
        let reader = NectoMessageSession(stream: incoming)
        defer { writer.close(); reader.close() }
        try await writer.send(Data())
        try await writer.send(Data([42]))
        #expect(try await reader.receive().isEmpty)
        #expect(try await reader.receive() == Data([42]))
    }

    @Test("a silent peer cannot hold a handshake open")
    func handshakeDeadline() async throws {
        let (peer, incoming) = try socketPair()
        let reader = NectoMessageSession(stream: incoming)
        defer { peer.close(); reader.close() }
        let start = ContinuousClock.now
        await #expect(throws: URLError.self) {
            try await reader.handshake(timeout: .milliseconds(30)) { try await reader.receive() }
        }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test("cancelling a blocked read completes without peer traffic", arguments: 0..<20)
    func cancelRead(_: Int) async throws {
        let (peer, incoming) = try socketPair()
        defer { peer.close(); incoming.close() }
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            started.continuation.yield(())
            return try await incoming.read(count: 4)
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test("closing cancels queued writes even when the peer never reads")
    func closeBlockedWrites() async throws {
        let (writer, peer) = try socketPair()
        defer { writer.close(); peer.close() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await #expect(throws: (any Error).self) {
                        try await writer.write(Data(repeating: 7, count: 1024 * 1024))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(20))
                writer.close()
                writer.close()
            }
        }
    }

    @Test("a failed Unix connection reports an error")
    func missingSocket() async {
        await #expect(throws: POSIXError.self) {
            try await NectoSocketStream.connect(unixPath: "/tmp/necto-missing-\(UUID().uuidString).sock")
        }
    }

    @Test("cancellation before connect does not leak or resume twice", arguments: 0..<30)
    func cancelConnect(_: Int) async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NectoSocketStream.connect(unixPath: "/tmp/necto-cancel-\(UUID().uuidString).sock")
        }
        await #expect(throws: (any Error).self) { try await task.value }
    }
}
