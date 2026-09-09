//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoTransport

/// An in-memory stream so framing can be tested without a device.
private final class LoopbackStream: NectoByteStream, @unchecked Sendable {
    private var buffer = Data()
    private(set) var isClosed = false

    func write(_ data: Data) throws {
        buffer.append(data)
    }

    /// Honours the contract: exactly `count` bytes, or it throws.
    func read(count: Int) throws -> Data {
        guard buffer.count >= count, count > 0 else {
            throw NectoSocketStream.Failure.closed
        }
        let piece = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(piece)
    }

    func close() { isClosed = true }

    var pending: Data { buffer }
}

private struct Payload: Codable, Equatable {
    let name: String
    let count: Int
}

@Test func framesAMessageWithABigEndianLength() async throws {
    let stream = LoopbackStream()
    let session = NectoMessageSession(stream: stream)

    try await session.send(Data([0xAA, 0xBB]))

    #expect(Array(stream.pending) == [0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB])
}

@Test func roundTripsAMessage() async throws {
    let stream = LoopbackStream()
    let session = NectoMessageSession(stream: stream)
    let message = Data("hello".utf8)

    try await session.send(message)

    #expect(try await session.receive() == message)
}

@Test func roundTripsCodableValues() async throws {
    let stream = LoopbackStream()
    let session = NectoMessageSession(stream: stream)
    let payload = Payload(name: "records", count: 3)

    try await session.send(payload)

    #expect(try await session.receive(Payload.self) == payload)
}

/// A socket delivers a byte stream, so a message can arrive split across reads.
/// Assembling it is the stream's job, which is why this runs over a real socket pair.
@Test func assemblesAMessageDeliveredInPieces() async throws {
    var descriptors: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)

    let writer = NectoSocketStream(descriptor: descriptors[0])
    let reader = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[1]))
    defer {
        writer.close()
        reader.close()
    }

    let message = Data("a longer message".utf8)
    var frame = Data()
    withUnsafeBytes(of: UInt32(message.count).bigEndian) { frame.append(contentsOf: $0) }
    frame.append(message)

    // Send one byte at a time to force the reader to stitch the frame together.
    for byte in frame {
        try await writer.write(Data([byte]))
    }

    #expect(try await reader.receive() == message)
}

@Test func failsAReadWhenTheSocketCloses() async throws {
    var descriptors: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)

    let writer = NectoSocketStream(descriptor: descriptors[0])
    let reader = NectoMessageSession(stream: NectoSocketStream(descriptor: descriptors[1]))
    defer { reader.close() }

    writer.close()

    await #expect(throws: NectoSocketStream.Failure.self) {
        try await reader.receive()
    }
}

@Test func keepsMessagesSeparateOnAContinuousStream() async throws {
    let stream = LoopbackStream()
    let session = NectoMessageSession(stream: stream)

    try await session.send(Data("first".utf8))
    try await session.send(Data("second".utf8))

    #expect(try await session.receive() == Data("first".utf8))
    #expect(try await session.receive() == Data("second".utf8))
}

@Test func refusesToSendBeyondTheFrameLimit() async {
    let session = NectoMessageSession(stream: LoopbackStream())
    let oversized = Data(count: NectoMessageSession.maximumMessageBytes + 1)

    await #expect(throws: NectoMessageSession.Failure.self) {
        try await session.send(oversized)
    }
}

@Test func refusesAnOversizedLengthPrefix() async throws {
    let stream = LoopbackStream()
    // A length prefix larger than the limit must not cause a huge allocation.
    try stream.write(Data([0x7F, 0xFF, 0xFF, 0xFF]))

    await #expect(throws: NectoMessageSession.Failure.self) {
        try await NectoMessageSession(stream: stream).receive()
    }
}

@Test func closingTheSessionClosesTheStream() async {
    let stream = LoopbackStream()
    NectoMessageSession(stream: stream).close()

    #expect(stream.isClosed)
}
