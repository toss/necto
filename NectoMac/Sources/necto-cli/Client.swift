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

        var description: String {
            switch self {
            case .notRunning:
                "Could not reach Necto. Is the app running?"
            case let .remote(code, message):
                "\(code): \(message)"
            case .protocolError:
                "Necto answered something this version of necto-cli does not understand"
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
    func stream(_ request: NectoControlRequest, onEvent: @escaping (NectoJSONValue) -> Void) async throws {
        let session = try await connect()

        // ^C should tell Necto to stop the stream, not just vanish. The signal handler
        // sends the cancel and the normal loop below sees the `end` that follows.
        Interrupt.install { [session] in
            Task { try? await session.send(NectoControlRequest(id: request.id, kind: .cancel)) }
        }
        defer {
            Interrupt.remove()
            session.close()
        }

        try await session.send(request)

        while true {
            guard let response = try? await session.receive(NectoControlResponse.self) else { return }
            guard response.id == request.id else { continue }

            switch response.kind {
            case .event:
                if let value = response.value { onEvent(value) }
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
    }
}

/// SIGINT plumbing for `subscribe`.
private enum Interrupt {
    nonisolated(unsafe) private static var source: DispatchSourceSignal?

    static func install(_ handle: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT)
        source.setEventHandler {
            handle()
            // Give the cancel a moment to travel, then leave the way ^C means.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(130) }
        }
        source.resume()
        self.source = source
    }

    static func remove() {
        source?.cancel()
        source = nil
        signal(SIGINT, SIG_DFL)
    }
}
