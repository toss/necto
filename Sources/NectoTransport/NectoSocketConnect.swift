//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

extension NectoSocketStream {
    public static func connect(to address: sockaddr_in) async throws -> NectoSocketStream {
        var address = address
        return try await connect(address: withUnsafeBytes(of: &address) { Data($0) }, domain: AF_INET)
    }

    public static func connect(unixPath: String) async throws -> NectoSocketStream {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = unixPath.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                let count = strlen(path) + 1
                guard count <= destination.count else { return false }
                memcpy(destination.baseAddress!, path, count)
                return true
            }
        }
        guard copied else { throw POSIXError(.ENAMETOOLONG) }
        return try await connect(address: withUnsafeBytes(of: &address) { Data($0) }, domain: AF_UNIX)
    }

    private static func connect(address: Data, domain: Int32) async throws -> NectoSocketStream {
        let attempt = try SocketConnectAttempt(domain: domain)
        return try await withThrowingTaskGroup(of: NectoSocketStream.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    let stream = try await attempt.connect(address: address)
                    if Task.isCancelled {
                        stream.close()
                        throw CancellationError()
                    }
                    return stream
                } onCancel: { attempt.cancel() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private final class SocketConnectAttempt: @unchecked Sendable {
    private let descriptor: Int32
    private let source: any DispatchSourceWrite
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NectoSocketStream, any Error>?
    private var finished = false
    private let ownership = Ownership()

    init(domain: Int32) throws {
        let descriptor = socket(domain, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.descriptor = descriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "im.toss.necto.connect"))
        let ownership = ownership
        source.setCancelHandler {
            if !ownership.lock.withLock({ ownership.transferred }) { Darwin.close(descriptor) }
        }
    }

    func connect(address: Data) async throws -> NectoSocketStream {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                guard !finished else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let result = address.withUnsafeBytes { bytes in
                    Darwin.connect(descriptor, bytes.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(bytes.count))
                }
                if result == 0 {
                    finishLocked(error: nil)
                    return
                }
                guard errno == EINPROGRESS else {
                    finishLocked(error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
                source.setEventHandler { [weak self] in self?.ready() }
                source.resume()
            }
        }
    }

    func cancel() {
        lock.withLock {
            guard !finished else { return }
            finishLocked(error: CancellationError())
        }
    }

    private func ready() {
        lock.withLock {
            guard !finished else { return }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) != 0 { error = errno }
            finishLocked(error: error == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
        }
    }

    private func finishLocked(error: (any Error)?) {
        finished = true
        if let error {
            continuation?.resume(throwing: error)
        } else {
            ownership.lock.withLock { ownership.transferred = true }
            continuation?.resume(returning: NectoSocketStream(descriptor: descriptor))
        }
        continuation = nil
        source.cancel()
        // activate is idempotent, including cancellation before connect starts.
        source.activate()
    }

    private final class Ownership: @unchecked Sendable {
        let lock = NSLock()
        var transferred = false
    }
}
