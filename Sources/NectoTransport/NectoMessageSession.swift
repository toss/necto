//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// A message oriented session over a byte stream.
///
/// Mirrors `PTChannel` in PeerTalk, reduced to what Necto needs. PeerTalk frames a
/// version, a type and a tag alongside the payload; Necto carries all of that inside
/// the Protocol v1 message itself, so the frame only needs a length.
public final class NectoMessageSession: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case messageTooLarge(Int)
        case concurrentReceive

        public var description: String {
            switch self {
            case let .messageTooLarge(size): "Message of \(size) bytes exceeds the frame limit"
            case .concurrentReceive: "Only one receiver may read a session at a time"
            }
        }
    }

    /// Guards against a malformed length prefix allocating unbounded memory.
    public static let maximumMessageBytes = 32 * 1024 * 1024

    private let stream: any NectoByteStream
    private let receiveLock = NSLock()
    private var receiving = false

    public init(stream: any NectoByteStream) {
        self.stream = stream
    }

    public func close() {
        stream.close()
    }

    /// Sends one message, framed as a 4 byte big endian length followed by the payload.
    public func send(_ message: Data) async throws {
        guard message.count <= Self.maximumMessageBytes else {
            throw Failure.messageTooLarge(message.count)
        }

        var frame = Data()
        withUnsafeBytes(of: UInt32(message.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(message)
        try await stream.write(frame)
    }

    /// Reads one message. The stream carries no message boundaries, so the length
    /// prefix is what separates them.
    public func receive() async throws -> Data {
        try receiveLock.withLock {
            guard !receiving else { throw Failure.concurrentReceive }
            receiving = true
        }
        defer { receiveLock.withLock { receiving = false } }
        let header = try await stream.read(count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(Self.maximumMessageBytes) else {
            close()
            throw Failure.messageTooLarge(Int(length))
        }
        return try await stream.read(count: Int(length))
    }

    public func send(_ value: some Encodable) async throws {
        try await send(JSONEncoder().encode(value))
    }

    public func receive<Value: Decodable>(_ type: Value.Type) async throws -> Value {
        try await JSONDecoder().decode(type, from: receive())
    }

    /// Cancelling or exceeding the deadline closes the session and cancels pending I/O.
    public func handshake<Value: Sendable>(
        timeout: Duration = .seconds(10),
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { [self] in
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await operation()
                } onCancel: {
                    close()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
