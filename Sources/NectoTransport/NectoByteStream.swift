//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// A bidirectional stream. Each write is delivered without interleaving other writes.
public protocol NectoByteStream: Sendable {
    func write(_ data: Data) async throws
    /// Reads exactly `count` bytes, or throws if the stream ends first.
    func read(count: Int) async throws -> Data
    func close()
}

/// Adapts asynchronous Dispatch I/O to Swift concurrency.
public final class NectoSocketStream: NectoByteStream, @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case closed
        public var description: String { "The connection closed" }
    }

    private let descriptor: Int32
    private let channel: DispatchIO
    private let queue = DispatchQueue(label: "im.toss.necto.socket")
    private let lock = NSLock()
    private var closed = false

    /// Takes ownership of a connected descriptor, including its eventual close.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            Darwin.close(descriptor)
        }
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            // Wake pending I/O; DispatchIO releases the descriptor after its callbacks finish.
            shutdown(descriptor, SHUT_RDWR)
            channel.close(flags: .stop)
        }
    }

    public func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
                channel.write(offset: 0, data: bytes, queue: queue) { done, _, error in
                    guard done else { return }
                    if error == 0 { continuation.resume() }
                    else { continuation.resume(throwing: Failure.closed) }
                }
            }
            try Task.checkCancellation()
        } onCancel: { close() }
    }

    public func read(count: Int) async throws -> Data {
        precondition(count >= 0)
        guard count > 0 else { return Data() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                let buffer = ReadBuffer()
                channel.read(offset: 0, length: count, queue: queue) { done, bytes, error in
                    if let bytes { buffer.data.append(contentsOf: bytes) }
                    guard done else { return }
                    if error == 0, buffer.data.count == count { continuation.resume(returning: buffer.data) }
                    else { continuation.resume(throwing: Failure.closed) }
                }
            }
            try Task.checkCancellation()
            return data
        } onCancel: { close() }
    }

    /// Accessed only by callbacks on the stream's serial queue.
    private final class ReadBuffer: @unchecked Sendable {
        var data = Data()
    }
}
