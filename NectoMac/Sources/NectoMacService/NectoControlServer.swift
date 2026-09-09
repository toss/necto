//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoCLIService
import NectoTransport
import Foundation

/// What the app answers the control socket with.
///
/// The server owns sockets and framing and nothing else; everything it is asked, it
/// asks this. The app delegates operations to the same registry the web panels use
/// and installations to its existing installer and approval flow.
public protocol NectoControlHandling: Sendable {
    func targets() async -> NectoJSONValue
    func plugins() async -> NectoJSONValue
    func installPlugin(from source: NectoPluginInstallSource) async throws -> NectoJSONValue
    func deletePlugin(id: String) async throws -> NectoJSONValue
    func invoke(
        pluginID: String,
        operationID: String,
        input: NectoJSONValue,
        app: String?,
        device: String?
    ) async throws -> NectoJSONValue
    /// Returns when the stream ends. Cancellation of the surrounding task is the stop.
    func subscribe(
        pluginID: String,
        operationID: String,
        input: NectoJSONValue,
        app: String?,
        device: String?,
        onEvent: @escaping @Sendable (NectoJSONValue) -> Void
    ) async throws
}

public extension NectoControlHandling {
    func deletePlugin(id: String) async throws -> NectoJSONValue {
        throw NectoBridgeError(code: .operationUnavailable, message: "This host does not support plugin deletion.")
    }
    func installPlugin(from source: NectoPluginInstallSource) async throws -> NectoJSONValue {
        throw NectoBridgeError(code: .operationUnavailable, message: "This host does not support plugin installation.")
    }
}

/// Listens on a Unix socket for control connections.
///
/// One accepted connection is one session: requests in, responses out, both framed by
/// `NectoMessageSession` exactly like every other Necto connection. The socket file is
/// created `0600`, so the boundary is the user account — the same boundary as the
/// plugins folder beside it.
public final class NectoControlServer: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case cannotListen(String)

        public var description: String {
            switch self {
            case let .cannotListen(reason): "Cannot open the control socket: \(reason)"
            }
        }
    }

    private let socketURL: URL
    private let handler: any NectoControlHandling
    private let lock = NSLock()
    private var acceptor: NectoSocketAcceptor?
    private var socketLease: SocketLease?
    private var acceptTask: Task<Void, Never>?
    private var connections: [UUID: (session: NectoMessageSession, task: Task<Void, Never>)] = [:]

    public init(socketURL: URL = NectoControlSocket.url(), handler: any NectoControlHandling) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard acceptor == nil else { return }
        let path = socketURL.path
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.cannotListen("socket() failed") }
        var ownsDescriptor = true
        defer { if ownsDescriptor { Darwin.close(fd) } }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw Failure.cannotListen("cannot protect the listening descriptor")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination -> Bool in
                let length = strlen(source)
                guard length < destination.count else { return false }
                memcpy(destination.baseAddress!, source, length + 1)
                return true
            }
        }
        guard copied else {
            throw Failure.cannotListen("socket path is too long: \(path)")
        }

        let lease = try SocketLease(path: path)
        try lease.removeStaleSocket(address: &address)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0 else {
            throw Failure.cannotListen(String(cString: strerror(errno)))
        }
        try lease.recordSocket()
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            throw Failure.cannotListen(String(cString: strerror(errno)))
        }

        let acceptor = try NectoSocketAcceptor(descriptor: fd)
        ownsDescriptor = false
        self.acceptor = acceptor
        socketLease = lease
        acceptTask = Task { [weak self] in
            do {
                for try await session in acceptor.sessions {
                    guard !Task.isCancelled else { session.close(); break }
                    self?.serve(session, from: acceptor)
                }
            } catch {}
        }
    }

    deinit { stop() }

    public func stop() {
        let active = lock.withLock {
            acceptTask?.cancel()
            acceptTask = nil
            acceptor?.close()
            acceptor = nil
            socketLease = nil
            defer { connections.removeAll() }
            return Array(connections.values)
        }
        for connection in active {
            connection.session.close()
            connection.task.cancel()
        }
    }

    private func serve(_ session: NectoMessageSession, from source: NectoSocketAcceptor) {
        let id = UUID()
        lock.withLock {
            guard acceptor === source else { session.close(); return }
            let task = Task { [weak self, handler] in
                let responder = Responder(session: session)
                let tasks = Requests()
                defer {
                    tasks.cancelAll()
                    responder.stop()
                    session.close()
                    _ = self?.lock.withLock { self?.connections.removeValue(forKey: id) }
                }
                while !Task.isCancelled {
                    guard let request = try? await session.receive(NectoControlRequest.self) else { break }
                    if request.kind == .cancel {
                        tasks.cancel(request.id)
                    } else {
                        tasks.start(for: request.id) {
                            await Self.handle(request, handler: handler, responder: responder)
                        }
                    }
                }
            }
            connections[id] = (session, task)
        }
    }

    private final class SocketLease {
        let path: String
        let descriptor: Int32
        var identity: stat?

        init(path: String) throws {
            self.path = path
            let fd = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw Failure.cannotListen("cannot open the socket lock") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd)
                throw Failure.cannotListen("socket lock is unsafe or another server is running")
            }
            descriptor = fd
        }

        deinit {
            if let identity { removeIfUnchanged(identity) }
            // Keep the lock inode: unlinking it lets a second process lock a different file.
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }

        func recordSocket() throws {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                  info.st_uid == getuid() else {
                throw Failure.cannotListen("socket path changed while starting")
            }
            identity = info
        }

        func removeStaleSocket(address: inout sockaddr_un) throws {
            var info = stat()
            if lstat(path, &info) != 0 {
                guard errno == ENOENT else { throw Failure.cannotListen("cannot inspect the socket path") }
                return
            }
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                throw Failure.cannotListen("socket path belongs to another file or user")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw Failure.cannotListen("cannot check the existing socket") }
            defer { Darwin.close(probe) }
            guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else {
                throw Failure.cannotListen("cannot check the existing socket without blocking")
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            // Older Necto versions have no lock file. Only a refused connection proves staleness.
            guard result != 0, errno == ECONNREFUSED else {
                throw Failure.cannotListen("the existing socket may still be in use")
            }
            removeIfUnchanged(info)
        }

        private func removeIfUnchanged(_ expected: stat) {
            var current = stat()
            if lstat(path, &current) == 0,
               current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
               current.st_mode & S_IFMT == S_IFSOCK, current.st_uid == getuid() {
                unlink(path)
            }
        }
    }

    private static func handle(
        _ request: NectoControlRequest,
        handler: any NectoControlHandling,
        responder: Responder
    ) async {
        do {
            switch request.kind {
            case .targets:
                responder.send(.init(id: request.id, kind: .result, value: await handler.targets()))

            case .plugins:
                responder.send(.init(id: request.id, kind: .result, value: await handler.plugins()))

            case .installPlugin:
                let source = try NectoPluginInstallSource(input: request.input ?? .null)
                let value = try await handler.installPlugin(from: source)
                responder.send(.init(id: request.id, kind: .result, value: value))

            case .deletePlugin:
                let deletion = try NectoPluginDeletion(pluginID: request.pluginID ?? "")
                let value = try await handler.deletePlugin(id: deletion.pluginID)
                responder.send(.init(id: request.id, kind: .result, value: value))

            case .invoke:
                let value = try await handler.invoke(
                    pluginID: request.pluginID ?? "",
                    operationID: request.operationID ?? "",
                    input: request.input ?? .object([:]),
                    app: request.app,
                    device: request.device
                )
                responder.send(.init(id: request.id, kind: .result, value: value))

            case .subscribe:
                try await handler.subscribe(
                    pluginID: request.pluginID ?? "",
                    operationID: request.operationID ?? "",
                    input: request.input ?? .object([:]),
                    app: request.app,
                    device: request.device
                ) { event in
                    responder.send(.init(id: request.id, kind: .event, value: event))
                }
                responder.send(.init(id: request.id, kind: .end))

            case .cancel:
                break
            }
        } catch is CancellationError {
            responder.send(.init(id: request.id, kind: .end))
        } catch {
            let bridged = error as? NectoBridgeError
            responder.send(.init(
                id: request.id,
                kind: .error,
                error: .init(
                    code: bridged?.code.rawValue ?? "FAILED",
                    message: bridged?.message ?? String(describing: error)
                )
            ))
        }
    }

    /// The handler's synchronous event callback feeds one bounded async writer.
    private final class Responder: Sendable {
        private let session: NectoMessageSession
        private let continuation: AsyncStream<NectoControlResponse>.Continuation
        private let task: Task<Void, Never>

        init(session: NectoMessageSession) {
            self.session = session
            let pair = AsyncStream<NectoControlResponse>.makeStream(bufferingPolicy: .bufferingOldest(64))
            continuation = pair.continuation
            task = Task {
                do {
                    for await response in pair.stream {
                        try await session.send(response)
                    }
                } catch { session.close() }
            }
        }

        func send(_ response: NectoControlResponse) {
            if case .dropped = continuation.yield(response) {
                session.close()
                stop()
            }
        }

        func stop() {
            continuation.finish()
            task.cancel()
        }
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

        func start(for id: String, operation: @escaping @Sendable () async -> Void) {
            lock.withLock {
                guard tasks[id] == nil else { return }
                let token = UUID()
                let task = Task {
                    await operation()
                    self.lock.withLock {
                        if self.tasks[id]?.token == token { self.tasks.removeValue(forKey: id) }
                    }
                }
                tasks[id] = (token, task)
            }
        }

        func cancel(_ id: String) {
            lock.withLock { tasks.removeValue(forKey: id) }?.task.cancel()
        }

        func cancelAll() {
            lock.withLock {
                for value in tasks.values { value.task.cancel() }
                tasks.removeAll()
            }
        }
    }
}
