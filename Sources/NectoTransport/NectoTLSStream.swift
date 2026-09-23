//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

public final class NectoTLSStream: NectoByteStream, @unchecked Sendable {
    /// Protected connections may need a person to approve private-key use in Keychain.
    public static let authenticationTimeout: Duration = .seconds(120)

    public enum Role: Sendable {
        case device(NectoPublicKeyPin)
        case host(NectoTLSIdentity)
    }

    enum Direction: Sendable { case incoming, outgoing }
    typealias WireTransform = @Sendable (Direction, Data) -> Data

    private let lock = NSLock()
    private var channel: (any Channel)?
    private var buffer = Data()
    private var failure: (any Error)?
    private var reachedEOF = false
    private var pending: (count: Int, continuation: CheckedContinuation<Data, any Error>)?
    private var tlsPromise: EventLoopPromise<Void>?
    private var tlsFinished = false
    private let limit: Int

    private init(limit: Int) { self.limit = limit }
    deinit { close() }

    /// Ownership passes to NIO. Callers must not read, write or close the descriptor again.
    static func adopt(
        descriptor: Int32,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        maximumBufferedBytes: Int = NectoMessageSession.maximumMessageBytes + 4,
        wireTransform: WireTransform? = nil
    ) async throws -> NectoTLSStream {
        let stream = NectoTLSStream(limit: maximumBufferedBytes)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    WireHandler(transform: wireTransform),
                    StreamHandler(stream: stream),
                ])
            }
            .withConnectedSocket(descriptor).get()
        stream.lock.withLock { stream.channel = channel }
        return stream
    }

    public func startTLS(_ role: Role, timeout: Duration = NectoTLSStream.authenticationTimeout) async throws {
        guard let channel = lock.withLock({ channel }) else { throw NectoSecurityError.closed }
        let session = NectoMessageSession(stream: self)
        try await session.handshake(timeout: timeout) { [self] in
            let future = try await channel.eventLoop.submit {
                let promise = try self.lock.withLock {
                    if let failure = self.failure { throw failure }
                    guard !self.reachedEOF else { throw NectoSecurityError.closed }
                    guard self.tlsPromise == nil, self.pending == nil else { throw NectoSecurityError.concurrentRead }
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    self.tlsPromise = promise
                    return promise
                }
                do {
                    let handler: NIOSSLHandler
                    switch role {
                    case let .device(pin):
                        var config = TLSConfiguration.makeClientConfiguration()
                        config.minimumTLSVersion = .tlsv13
                        config.certificateVerification = .noHostnameVerification
                        handler = try NIOSSLClientHandler(
                            context: NIOSSLContext(configuration: config), serverHostname: nil,
                            customVerificationCallback: { certificates, result in
                                result.succeed(certificates.first.map(pin.matches) == true ? .certificateVerified : .failed)
                            }
                        )
                    case let .host(identity):
                        handler = NIOSSLServerHandler(context: try NIOSSLContext(configuration: identity.configuration()))
                    }
                    let pipeline = channel.pipeline.syncOperations
                    let wire = try pipeline.context(handlerType: WireHandler.self)
                    try pipeline.addHandler(handler, position: .after(wire.handler))
                    // TLS records may arrive in the same socket read as the public discovery frame.
                    let buffered = self.lock.withLock {
                        let bytes = self.buffer
                        self.buffer.removeAll(keepingCapacity: false)
                        return bytes
                    }
                    if !buffered.isEmpty { wire.fireChannelRead(NIOAny(ByteBuffer(bytes: buffered))) }
                } catch {
                    self.fail(error)
                }
                return promise.futureResult
            }.get()
            try await future.get()
        }
    }

    public var isTLSReady: Bool { lock.withLock { tlsFinished && failure == nil && !reachedEOF } }

    func negotiatedTLSVersion() async throws -> TLSVersion? {
        guard let channel = lock.withLock({ channel }) else { throw NectoSecurityError.closed }
        return try await channel.nioSSL_tlsVersion().get()
    }

    public func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let channel = try lock.withLock {
                if let failure { throw failure }
                guard !reachedEOF else { throw NectoSecurityError.closed }
                guard let channel = self.channel else { throw NectoSecurityError.closed }
                return channel
            }
            try await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
        } onCancel: { close() }
    }

    public func read(count: Int) async throws -> Data {
        precondition(count >= 0)
        guard count > 0 else { return Data() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if let failure { continuation.resume(throwing: failure) }
                    else if pending != nil { continuation.resume(throwing: NectoSecurityError.concurrentRead) }
                    else if count > limit { continuation.resume(throwing: NectoSecurityError.bufferLimit) }
                    else if buffer.count >= count { continuation.resume(returning: consume(count)) }
                    else if reachedEOF { continuation.resume(throwing: NectoSecurityError.closed) }
                    else { pending = (count, continuation) }
                }
            }
        } onCancel: { close() }
    }

    public func close() {
        fail(NectoSecurityError.closed)
        let closing = lock.withLock {
            let closing = channel
            channel = nil
            return closing
        }
        closing?.close(promise: nil)
    }

    private func consume(_ count: Int) -> Data {
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    fileprivate func receive(_ data: Data) {
        let overflow = lock.withLock {
            guard failure == nil, !reachedEOF else { return false }
            guard data.count <= limit - buffer.count else { return true }
            buffer.append(data)
            if let pending, buffer.count >= pending.count {
                self.pending = nil
                pending.continuation.resume(returning: consume(pending.count))
            }
            return false
        }
        if overflow {
            fail(NectoSecurityError.bufferLimit)
            close()
        }
    }

    fileprivate func completeTLS() {
        lock.withLock {
            guard failure == nil, !reachedEOF, !tlsFinished else { return }
            tlsFinished = true
            tlsPromise?.succeed(())
        }
    }

    fileprivate func endOfStream() {
        lock.withLock {
            guard failure == nil, !reachedEOF else { return }
            reachedEOF = true
            // A clean peer close must not discard complete frames awaiting a reader.
            pending?.continuation.resume(throwing: NectoSecurityError.closed)
            pending = nil
            if !tlsFinished {
                tlsPromise?.fail(NectoSecurityError.closed)
                tlsPromise = nil
            }
        }
    }

    fileprivate func fail(_ error: any Error) {
        lock.withLock {
            guard failure == nil else { return }
            failure = error
            buffer.removeAll()
            pending?.continuation.resume(throwing: error)
            pending = nil
            if !tlsFinished { tlsPromise?.fail(error) }
        }
    }
}

private final class StreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    // The stream owns the channel. A strong reference here would keep both alive after session release.
    weak var stream: NectoTLSStream?
    init(stream: NectoTLSStream) { self.stream = stream }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        stream?.receive(Data(unwrapInboundIn(data).readableBytesView))
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { stream?.completeTLS() }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        stream?.fail(error)
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        stream?.endOfStream()
        context.fireChannelInactive()
    }
}

private final class WireHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let transform: NectoTLSStream.WireTransform?
    init(transform: NectoTLSStream.WireTransform?) { self.transform = transform }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        context.fireChannelRead(wrapInboundOut(ByteBuffer(bytes: transform?(.incoming, bytes) ?? bytes)))
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = Data(unwrapOutboundIn(data).readableBytesView)
        context.write(wrapOutboundOut(ByteBuffer(bytes: transform?(.outgoing, bytes) ?? bytes)), promise: promise)
    }
}
