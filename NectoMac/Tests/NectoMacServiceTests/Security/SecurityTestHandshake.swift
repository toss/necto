//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import NectoTransport

/// A peer fixture for transport-level fault injection. Production admission is tested separately.
enum SecurityTestHandshake {
    private struct Offer: Codable {
        let type: String
        let version: Int
        let appBundleID: String
    }

    /// Only return a session that the SDK runtime is allowed to accept.
    static func device(
        stream: NectoTLSStream, publicKey: String?, appBundleID: String,
        timeout: Duration = .seconds(3)
    ) async throws -> NectoMessageSession {
        let session = NectoMessageSession(stream: stream)
        guard let publicKey else { return session }
        do {
            let pin = try NectoPublicKeyPin(publicKey)
            guard !appBundleID.isEmpty else { throw NectoSecurityError.unsupportedNegotiation }
            return try await session.handshake(timeout: timeout) {
                try await session.send(Offer(type: "necto.security", version: 1, appBundleID: appBundleID))
                try await stream.startTLS(.device(pin), timeout: timeout)
                return session
            }
        } catch {
            session.close()
            throw error
        }
    }

    static func host(
        stream: NectoTLSStream, timeout: Duration = .seconds(3),
        identity: @escaping @Sendable (String) throws -> NectoTLSIdentity?
    ) async throws -> NectoMessageSession {
        let session = NectoMessageSession(stream: stream)
        do {
            return try await session.handshake(timeout: timeout) {
                let first = try await session.receive()
                let object = try JSONSerialization.jsonObject(with: first) as? [String: Any]
                if object?["type"] != nil {
                    let offer = try JSONDecoder().decode(Offer.self, from: first)
                    guard offer.type == "necto.security", offer.version == 1, !offer.appBundleID.isEmpty else {
                        throw NectoSecurityError.unsupportedNegotiation
                    }
                    // The bundle ID only selects a key. It is not proof of the device app's identity.
                    guard let credential = try identity(offer.appBundleID) else { throw NectoSecurityError.unauthorized }
                    try await stream.startTLS(.host(credential), timeout: timeout)
                    return session
                }
                _ = try JSONDecoder().decode(NectoHandshakeHello.self, from: first)
                var prefix = Data()
                withUnsafeBytes(of: UInt32(first.count).bigEndian) { prefix.append(contentsOf: $0) }
                prefix.append(first)
                return NectoMessageSession(stream: PrefixedStream(prefix: prefix, base: stream))
            }
        } catch {
            session.close()
            throw error
        }
    }
}

private final class PrefixedStream: NectoByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var prefix: Data
    private let base: NectoTLSStream
    init(prefix: Data, base: NectoTLSStream) { self.prefix = prefix; self.base = base }
    func read(count: Int) async throws -> Data {
        let first = lock.withLock {
            let first = Data(prefix.prefix(count))
            prefix.removeFirst(first.count)
            return first
        }
        if first.count == count { return first }
        return try await first + base.read(count: count - first.count)
    }
    func write(_ data: Data) async throws { try await base.write(data) }
    func close() { base.close() }
}
