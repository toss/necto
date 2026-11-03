//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// A loopback HTTP/1.1 server small enough to read in one sitting.
///
/// The capture sits between an app and the network, so what it changes can only be
/// seen from the far side: which headers and bytes actually arrived, and when the
/// response bytes left. One connection carries one exchange and is then closed.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        /// Header names lowercased.
        let headers: [String: String]
        let body: Data
    }

    /// Writes one response. Everything is sent as it is written, so a responder that
    /// waits between two writes is a response that streams.
    final class Response: @unchecked Sendable {
        private let descriptor: Int32

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        func send(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            var fields = headers
            fields["Content-Length"] = String(body.count)
            sendHead(status: status, headers: fields)
            write(body)
        }

        /// Starts a response whose length is unknown until the connection closes.
        func sendHead(status: Int, headers: [String: String]) {
            var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\n"
            for (name, value) in headers.merging(["Connection": "close"], uniquingKeysWith: { $1 }) {
                head += "\(name): \(value)\r\n"
            }
            write(Data((head + "\r\n").utf8))
        }

        func write(_ data: Data) {
            data.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(descriptor, bytes.baseAddress! + sent, bytes.count - sent, 0)
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }
    }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var received: [Request] = []
    private var isStopped = false
    /// Signalled when the accepting thread has ended.
    private let accepting = DispatchSemaphore(value: 0)
    private let respond: @Sendable (Request, Response) -> Void

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Every request that arrived, in order.
    var requests: [Request] { lock.withLock { received } }

    init(respond: @escaping @Sendable (Request, Response) -> Void) throws {
        self.respond = respond
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }

        var enabled: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(listener, address, length) == 0
                    && listen(listener, 128) == 0
                    && getsockname(listener, address, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        self.listener = listener
        port = UInt16(bigEndian: address.sin_port)

        Thread.detachNewThread { [self] in
            defer { accepting.signal() }
            while true {
                let descriptor = accept(listener, nil, nil)
                guard descriptor >= 0 else { return }
                guard !lock.withLock({ isStopped }) else {
                    Darwin.close(descriptor)
                    return
                }
                var enabled: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in serve(descriptor) }
            }
        }
    }

    /// Returns once nothing is listening any more.
    ///
    /// The descriptor's number is free for the next server the moment it is closed, so
    /// the accepting thread has to be gone first. A connection is what wakes it.
    func stop() {
        lock.withLock { isStopped = true }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        address.sin_port = port.bigEndian
        let wake = socket(AF_INET, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                connect(wake, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        Darwin.close(wake)
        accepting.wait()
        Darwin.close(listener)
    }

    private func serve(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        guard let request = Self.read(from: descriptor) else { return }
        lock.withLock { received.append(request) }
        respond(request, Response(descriptor: descriptor))
    }

    // MARK: Parsing

    private static func read(from descriptor: Int32) -> Request? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard fill(&buffer, from: descriptor) else { return nil }
        }
        let headEnd = buffer.range(of: separator)!
        let lines = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var rest = Data(buffer[headEnd.upperBound...])
        let body: Data
        if let length = headers["content-length"].flatMap(Int.init) {
            while rest.count < length {
                guard fill(&rest, from: descriptor) else { return nil }
            }
            body = rest.prefix(length)
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = readChunked(&rest, from: descriptor) else { return nil }
            body = decoded
        } else {
            body = Data()
        }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    private static func readChunked(_ buffer: inout Data, from descriptor: Int32) -> Data? {
        var body = Data()
        let lineEnd = Data("\r\n".utf8)
        while true {
            while buffer.range(of: lineEnd) == nil {
                guard fill(&buffer, from: descriptor) else { return nil }
            }
            let sizeEnd = buffer.range(of: lineEnd)!
            let sizeText = String(decoding: buffer[..<sizeEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.split(separator: ";").first ?? "", radix: 16) else { return nil }
            buffer = Data(buffer[sizeEnd.upperBound...])
            if size == 0 { return body }
            while buffer.count < size + 2 {
                guard fill(&buffer, from: descriptor) else { return nil }
            }
            body.append(buffer.prefix(size))
            buffer = Data(buffer.dropFirst(size + 2))
        }
    }

    private static func fill(_ buffer: inout Data, from descriptor: Int32) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = recv(descriptor, &chunk, chunk.count, 0)
        guard count > 0 else { return false }
        buffer.append(chunk, count: count)
        return true
    }
}
