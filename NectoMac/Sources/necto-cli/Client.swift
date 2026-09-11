//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import ArgumentParser
import NectoCLIService
import NectoModel
import NectoTransport
import Foundation

/// One request, one connection.
///
/// A CLI invocation is a single question, so there is nothing to pool: connect, ask,
/// print, exit. `stream` holds the connection open until the stream ends or the user
/// interrupts.
struct Client {
    enum Failure: Error, CustomStringConvertible {
        case notRunning
        case remote(code: String, message: String)
        case protocolError
        case disconnected

        var description: String {
            switch self {
            case .notRunning:
                "Could not reach Necto. Is the app running?"
            case let .remote(code, message):
                displayText("\(code): \(message)")
            case .protocolError:
                "Necto answered something this version of necto-cli does not understand"
            case .disconnected:
                "Necto disconnected before the stream completed."
            }
        }
    }

    private func connect() async throws -> NectoMessageSession {
        do {
            let stream = try await NectoSocketStream.connect(unixPath: NectoControlSocket.url().path)
            return NectoMessageSession(stream: stream)
        } catch { throw Failure.notRunning }
    }

    /// Sends one request and returns its single result.
    func request(_ request: NectoControlRequest) async throws -> NectoJSONValue {
        let session = try await connect()
        defer { session.close() }
        try await session.send(request)

        while true {
            guard let response = try? await session.receive(NectoControlResponse.self) else {
                throw Failure.protocolError
            }
            guard response.id == request.id else { continue }

            switch response.kind {
            case .result:
                return response.value ?? .object([:])
            case .error:
                throw Failure.remote(
                    code: response.error?.code ?? "FAILED",
                    message: response.error?.message ?? "The request failed"
                )
            case .end:
                throw Failure.remote(code: "CANCELLED", message: "The request was cancelled.")
            case .event:
                throw Failure.protocolError
            }
        }
    }

    /// Follows a stream, calling `onEvent` per event, until `end`, an error, or ^C.
    func stream(
        _ request: NectoControlRequest, limit: Int? = nil, timeout: Duration? = nil,
        onEvent: @escaping (NectoJSONValue) -> Void
    ) async throws {
        let session = try await connect()
        let control = StreamControl(session: session)
        let interrupt = Interrupt { control.stop(.interrupted) }
        let timer = timeout.map { duration in
            Task {
                do { try await Task.sleep(for: duration) }
                catch { return }
                control.stop(.timeout)
            }
        }
        defer {
            timer?.cancel()
            interrupt.remove()
            session.close()
        }
        try await withTaskCancellationHandler {
            do {
                try await session.send(request)
                var count = 0
                while true {
                    let response: NectoControlResponse
                    do { response = try await session.receive(NectoControlResponse.self) }
                    catch { throw Failure.disconnected }
                    if control.reason != nil { break }
                    guard response.id == request.id else { continue }
                    switch response.kind {
                    case .event:
                        if let value = response.value {
                            onEvent(value)
                            count += 1
                            if let limit, count >= limit { return }
                        }
                    case .end:
                        return
                    case .error:
                        throw Failure.remote(
                            code: response.error?.code ?? "FAILED",
                            message: response.error?.message ?? "The stream failed"
                        )
                    case .result:
                        throw Failure.protocolError
                    }
                }
            } catch {
                if control.reason == nil { throw error }
            }
            switch control.reason {
            case .interrupted: throw ExitCode(130)
            case .cancelled: throw CancellationError()
            case .timeout: return
            case nil: throw Failure.disconnected
            }
        } onCancel: {
            control.stop(.cancelled)
        }
    }
}

private final class StreamControl: @unchecked Sendable {
    enum Reason { case timeout, interrupted, cancelled }
    private let lock = NSLock()
    private var stopped: Reason?
    private let session: NectoMessageSession

    init(session: NectoMessageSession) { self.session = session }

    var reason: Reason? { lock.withLock { stopped } }

    func stop(_ reason: Reason) {
        lock.withLock { if stopped == nil { stopped = reason } }
        // This command owns its connection; the host cancels its requests on EOF.
        session.close()
    }
}

private final class Interrupt {
    private let source: DispatchSourceSignal

    init(_ handle: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT)
        source.setEventHandler(handler: handle)
        source.resume()
        self.source = source
    }

    func remove() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
