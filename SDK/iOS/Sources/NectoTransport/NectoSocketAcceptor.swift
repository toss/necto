//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// Owns a listening descriptor. Readiness callbacks only perform nonblocking accept.
///
/// `sessions` ends with an error once the listening socket stops listening, so whoever
/// owns the acceptor knows to build another.
public final class NectoSocketAcceptor: @unchecked Sendable {
    public let sessions: AsyncThrowingStream<NectoMessageSession, any Error>
    private let continuation: AsyncThrowingStream<NectoMessageSession, any Error>.Continuation
    private let source: any DispatchSourceRead
    private let teardown: any DispatchSourceWrite

    /// Takes ownership only after initialization succeeds.
    public init(descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let pair = AsyncThrowingStream<NectoMessageSession, any Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        sessions = pair.stream
        continuation = pair.continuation
        let continuation = pair.continuation
        let queue = DispatchQueue(label: "im.toss.necto.accept")
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        teardown = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            for _ in 0..<16 {
                guard let self, !self.source.isCancelled else { return }
                let accepted = Darwin.accept(descriptor, nil, nil)
                if accepted < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
                let session = NectoMessageSession(stream: NectoSocketStream(descriptor: accepted))
                switch continuation.yield(session) {
                case .enqueued: break
                case .dropped, .terminated: session.close()
                @unknown default: session.close()
                }
            }
        }
        // iOS takes the sockets of a suspended app. A listening socket it took refuses
        // every connection, so it never becomes readable and nonblocking accept keeps
        // reporting EAGAIN: nothing above would ever notice. A listening socket is
        // never writable either, until the kernel tears it down and reports EOF there.
        teardown.setEventHandler { continuation.finish(throwing: POSIXError(.ECONNABORTED)) }
        // The descriptor outlives both sources: each cancellation has to be delivered
        // before it is closed.
        source.setCancelHandler { [teardown] in teardown.cancel() }
        teardown.setCancelHandler { Darwin.close(descriptor) }
        continuation.onTermination = { [weak self] _ in self?.close() }
        source.resume()
        teardown.resume()
    }

    deinit { close() }

    public func close() {
        source.cancel()
        continuation.finish()
    }
}
