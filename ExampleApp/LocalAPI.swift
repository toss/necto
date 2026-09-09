//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// A tiny REST server inside the app, so the traffic demo needs no internet.
///
/// The network plugin captures requests as `URLProtocol` sees them, which happens
/// long before anything reaches a network. Pointing the demo at a public API only
/// added ways for it to fail: a corporate connection that inspects TLS, an offline
/// device, a rate limit, a service that went away. Answering locally removes all of
/// them, and lets each route produce exactly the status, delay and size it is meant
/// to demonstrate.
final class LocalAPI: @unchecked Sendable {
    static let shared = LocalAPI()

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var boundPort: UInt16 = 0

    /// The origin to send demo requests to, once `start()` has bound a port.
    var origin: String { "http://127.0.0.1:\(lock.withLock { boundPort })" }

    private init() {}

    func start() {
        lock.lock()
        guard descriptor < 0 else {
            lock.unlock()
            return
        }
        lock.unlock()

        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return }

        var enabled: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // Port 0 asks the OS for a free one, so the demo never collides with whatever
        // else the machine is running.
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(socketDescriptor, address, size)
            }
        }
        guard bound == 0, listen(socketDescriptor, 8) == 0 else {
            close(socketDescriptor)
            return
        }

        var actual = sockaddr_in()
        var actualSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getsockname(socketDescriptor, address, &actualSize)
            }
        }

        lock.withLock {
            descriptor = socketDescriptor
            boundPort = UInt16(bigEndian: actual.sin_port)
        }

        // Blocking accept, so it gets a thread rather than a task.
        let thread = Thread { [weak self] in
            while let self, let client = self.accept(on: socketDescriptor) {
                Thread.detachNewThread { self.answer(client) }
            }
        }
        thread.name = "im.toss.necto.example.api"
        thread.start()
    }

    private func accept(on socketDescriptor: Int32) -> Int32? {
        let client = Darwin.accept(socketDescriptor, nil, nil)
        return client >= 0 ? client : nil
    }

    // MARK: Routing

    private func answer(_ client: Int32) {
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let read = recv(client, &buffer, buffer.count, 0)
        guard read > 0 else { return }

        let request = String(decoding: buffer[..<read], as: UTF8.self)
        let start = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = start.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"

        let (status, body) = route(path)
        send(status: status, body: body, to: client)
    }

    private func route(_ path: String) -> (Int, String) {
        switch path {
        case let path where path.hasPrefix("/posts/999"):
            return (404, #"{"error":"No post with that id"}"#)

        case let path where path.hasPrefix("/posts/"):
            return (200, post(id: 1))

        case let path where path.hasPrefix("/posts"):
            let posts = (1 ... 10).map(post(id:)).joined(separator: ",")
            return (200, "[\(posts)]")

        case "/session":
            return (204, "")

        case "/encrypt":
            // Stands in for the company encrypt service: field values in, ticket out.
            return (200, #"{"payload":"ticket-ok"}"#)

        case "/error":
            return (500, #"{"error":"Something went wrong on the server"}"#)

        case "/slow":
            // Long enough to stand out beside the fast rows in the plugin.
            Thread.sleep(forTimeInterval: 2)
            return (200, #"{"slept":"2s"}"#)

        case "/large":
            // Past the plugin's capture limit, so truncation is demonstrated.
            let items = (1 ... 4000).map {
                #"{"id":\#($0),"label":"row \#($0)","note":"a line of text to make this large"}"#
            }
            return (200, "{\"items\":[\(items.joined(separator: ","))]}")

        default:
            return (404, #"{"error":"No such route"}"#)
        }
    }

    private func post(id: Int) -> String {
        #"{"id":\#(id),"userId":1,"title":"Post \#(id)","body":"Written by Necto Example."}"#
    }

    private func send(status: Int, body: String, to client: Int32) {
        let reason = [200: "OK", 201: "Created", 204: "No Content", 404: "Not Found", 500: "Internal Server Error"]
        let payload = Array(body.utf8)

        let head = """
        HTTP/1.1 \(status) \(reason[status] ?? "OK")\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(payload.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """

        var out = Array(head.utf8)
        out.append(contentsOf: payload)
        out.withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, $0.count, 0) }
    }
}
