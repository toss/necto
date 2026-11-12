//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoTransport

/// Accepts connections on a TCP port inside the connected app.
///
/// The socket roles are the opposite of the protocol roles. usbmuxd can only reach a
/// port that the device is already listening on, so the app listens and the Mac
/// connects, even though the Mac is the host that drives the session.
///
/// Mirrors the listening half of `PTChannel` in PeerTalk.
public final class NectoDeviceListener: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case cannotListen(String)

        public var description: String {
            switch self {
            case let .cannotListen(reason): "Cannot listen for Necto connections: \(reason)"
            }
        }
    }

    /// The port Necto uses over USB. usbmuxd tunnels to it from the Mac.
    public static let defaultPort = NectoTransportDefaults.devicePort

    /// How many ports an app slides across when the first is taken. Simulators share
    /// the Mac's loopback and a device shares its own, so on both the second app lands
    /// one port later. The Mac probes the whole span on both transports.
    public static let portSpan = NectoTransportDefaults.portSpan

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var acceptor: NectoSocketAcceptor?

    /// The port actually bound. Passing `0` asks the OS to pick one, and this is where
    /// the chosen port shows up, so a test never has to occupy the real one.
    private var storedPort: UInt16
    public var port: UInt16 { lock.withLock { storedPort } }

    public init(port: UInt16 = NectoDeviceListener.defaultPort) {
        storedPort = port
    }

    deinit { stop() }

    public func start() throws {
        try lock.withLock {
            guard descriptor < 0 else { return }
            try startLocked()
        }
    }

    private func startLocked() throws {
        try rejectWildcardListener()
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Failure.cannotListen(String(cString: strerror(errno)))
        }

        // Allows an immediate restart after the app relaunches, instead of waiting
        // for the previous socket to leave TIME_WAIT.
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = storedPort.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, size)
            }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            stopLocked()
            throw Failure.cannotListen(reason)
        }

        guard listen(descriptor, 4) == 0 else {
            let reason = String(cString: strerror(errno))
            stopLocked()
            throw Failure.cannotListen(reason)
        }

        if storedPort == 0 {
            var bound = sockaddr_in()
            var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
            let read = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    getsockname(descriptor, address, &boundSize)
                }
            }
            if read == 0 { storedPort = UInt16(bigEndian: bound.sin_port) }
        }
        do {
            acceptor = try NectoSocketAcceptor(descriptor: descriptor)
        } catch {
            stopLocked()
            throw error
        }
    }

    private func rejectWildcardListener() throws {
        guard storedPort != 0 else { return }
        // SO_REUSEADDR can let a loopback bind shadow an older SDK's wildcard listener.
        // Probe the wildcard address without listening; the actual listener stays loopback-only.
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw Failure.cannotListen(String(cString: strerror(errno))) }
        defer { Darwin.close(probe) }
        var enabled: Int32 = 1
        guard setsockopt(probe, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Failure.cannotListen(String(cString: strerror(errno)))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = storedPort.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw Failure.cannotListen(String(cString: strerror(errno))) }
    }

    public func stop() { lock.withLock { stopLocked() } }

    private func stopLocked() {
        if let acceptor {
            self.acceptor = nil
            descriptor = -1
            acceptor.close()
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    public func accept() async throws -> NectoMessageSession {
        var iterator = sessions().makeAsyncIterator()
        guard let session = try await iterator.next() else { throw Failure.cannotListen("Listener stopped") }
        return session
    }

    public func sessions() -> AsyncThrowingStream<NectoMessageSession, any Error> {
        guard let acceptor = lock.withLock({ self.acceptor }) else {
            return AsyncThrowingStream { $0.finish(throwing: Failure.cannotListen("Listener is not running")) }
        }
        return acceptor.sessions
    }
}
