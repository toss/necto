//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoTransport

/// A connection to the usbmuxd unix socket.
///
/// Mirrors `PTUSBChannel` in PeerTalk (`PTUSBHub.m`), ported to Swift so this package
/// stays dependency free. Names are kept close to the original so upstream changes
/// remain easy to follow.
///
/// usbmuxd frames every control message as a 16 byte header followed by a plist.
/// After a successful `Connect` the same socket becomes a raw pipe to the device,
/// which is why raw reads and writes stay available once the control phase ends.
final class NectoUSBChannel: NectoByteStream, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case cannotOpen(String)
        case closed
        case malformedResponse

        var description: String {
            switch self {
            case let .cannotOpen(reason): "Cannot reach usbmuxd: \(reason)"
            case .closed: "The usbmuxd connection closed"
            case .malformedResponse: "usbmuxd sent a malformed response"
            }
        }
    }

    static let socketPath = "/var/run/usbmuxd"

    private let stream: NectoSocketStream
    private let controlLock = NSLock()
    private var nextTag: UInt32 = 1

    init() async throws {
        stream = try await NectoSocketStream.connect(unixPath: Self.socketPath)
    }

    deinit { close() }

    func close() {
        stream.close()
    }

    // MARK: Control phase

    /// Sends a plist request. Mirrors `-sendRequest:callback:`.
    @discardableResult
    func send(request: [String: Any]) async throws -> UInt32 {
        let tag = controlLock.withLock {
            defer { nextTag &+= 1 }
            return nextTag
        }

        let payload = try PropertyListSerialization.data(
            fromPropertyList: request,
            format: .xml,
            options: 0
        )

        var frame = Data()
        frame.appendLittleEndian(UInt32(16 + payload.count))
        frame.appendLittleEndian(UInt32(1)) // usbmux protocol version
        frame.appendLittleEndian(UInt32(8)) // plist packet type
        frame.appendLittleEndian(tag)
        frame.append(payload)

        try await write(frame)
        return tag
    }

    func receiveResponse() async throws -> [String: Any] {
        let header = try await read(count: 16)
        let length = header.littleEndianUInt32(at: 0)
        guard length >= 16, length <= NectoMessageSession.maximumMessageBytes else {
            throw Failure.malformedResponse
        }

        let payload = try await read(count: Int(length) - 16)
        guard let plist = try PropertyListSerialization.propertyList(
            from: payload,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw Failure.malformedResponse
        }
        return plist
    }

    // MARK: Raw I/O

    func write(_ data: Data) async throws {
        try await stream.write(data)
    }

    func read(count: Int) async throws -> Data {
        try await stream.read(count: count)
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        self[offset ..< offset + 4].reduce(UInt32(0)) { result, byte in
            (result >> 8) | (UInt32(byte) << 24)
        }
    }
}
