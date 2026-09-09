//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoDefaultPlugins
import NectoModel
import NectoSDK
import Foundation

/// The network plugin with `URLSession` capture already wired.
///
/// For the app that just wants its traffic in Necto:
///
/// ```swift
/// NectoSDK.register(URLSessionNetworkPlugin())
/// ```
///
/// Capture starts when the plugin is registered — the two are one decision, so they
/// are one line. An app that reports some requests itself as well reaches the plugin
/// through `network`.
public struct URLSessionNetworkPlugin: NectoPluginable {
    public let network = DefaultNetworkPlugin()

    public var id: String { network.id }

    public var panel: NectoPluginPanel? { network.panel }

    public init() {}

    public func register(_ necto: NectoHandler) {
        network.register(necto)
        NectoURLSessionCapture.install(reporting: network)
    }
}

/// Captures `URLSession` traffic and reports it to whatever takes reports.
///
/// One possible source of network records, offered because many apps do use
/// `URLSession` and wiring it up by hand is tedious. It is a module of its own so
/// that an app which routes traffic some other way never links it, and so that Necto
/// never assumes this is how requests are made.
///
/// `URLSessionNetworkPlugin` above is the one-liner; these entry points are for an
/// app that pairs the capture with a reporter of its own.
public enum NectoURLSessionCapture {
    /// Starts capturing. Records go to `plugin` until `remove()` is called.
    ///
    /// This installs a `URLProtocol` into the app's loading system, which affects
    /// sessions built from `URLSessionConfiguration.default`. Sessions the app
    /// configures itself need `NectoURLSessionCapture.protocolClass` in their own
    /// `protocolClasses`.
    /// Takes anything that reports, not the shipped plugin specifically. An app that
    /// decrypts its own traffic reports from wherever it already knows about a request.
    public static func install(reporting reporter: any NectoNetworkReporting) {
        NectoNetworkObserver.start { record in reporter.report(record) }
    }

    public static func remove() {
        NectoNetworkObserver.stop()
    }

    /// For apps that build their own `URLSessionConfiguration`.
    public static var protocolClass: AnyClass { NectoNetworkObserver.self }
}

/// Observes URLSession traffic without the app having to report anything.
///
/// `URLProtocol` is the only hook that sees requests an app already makes. Registering
/// one and then re-issuing the request through a session that excludes it lets Necto
/// time and inspect the exchange while the app's own code stays untouched.
///
/// It only observes: the request is passed through unchanged and the response is
/// handed back exactly as received.
final class NectoNetworkObserver: URLProtocol, @unchecked Sendable {
    /// Marks a request that this protocol already handled, so re-issuing it does not
    /// recurse back into the observer.
    private static let handledKey = "NectoNetworkObserverHandled"

    /// URLProtocol is instantiated by the loading system, so the reporting callback
    /// has to reach it through shared state rather than an initialiser.
    private final class Reporter: @unchecked Sendable {
        private let lock = NSLock()
        private var report: (@Sendable (NectoNetworkRecord) -> Void)?

        func set(_ report: (@Sendable (NectoNetworkRecord) -> Void)?) {
            lock.withLock { self.report = report }
        }

        func emit(_ record: NectoNetworkRecord) {
            let report = lock.withLock { self.report }
            report?(record)
        }
    }

    private static let reporter = Reporter()

    private var observedTask: URLSessionDataTask?
    private var received = 0
    private var responseData = Data()
    private var httpResponse: HTTPURLResponse?
    private var startedAt = Date()
    private var recordID = UUID().uuidString

    /// Starts observing. Records are handed to `report` as they start and finish.
    static func start(report: @escaping @Sendable (NectoNetworkRecord) -> Void) {
        reporter.set(report)
        URLProtocol.registerClass(NectoNetworkObserver.self)
    }

    static func stop() {
        URLProtocol.unregisterClass(NectoNetworkObserver.self)
        reporter.set(nil)
    }

    private static func emit(_ record: NectoNetworkRecord) {
        reporter.emit(record)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        return request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        startedAt = Date()
        Self.emit(makeRecord(state: .pending))

        // A session without this protocol registered, or the re-issued request would
        // be intercepted again.
        let session = URLSession(configuration: .ephemeral)
        observedTask = session.dataTask(with: mutable as URLRequest) { [weak self] data, response, error in
            guard let self else { return }

            if let data {
                received = data.count
                responseData = data
                client?.urlProtocol(self, didLoad: data)
            }
            if let response {
                httpResponse = response as? HTTPURLResponse
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }

            if let error {
                Self.emit(makeRecord(state: .failed, error: error))
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                Self.emit(makeRecord(
                    state: .completed,
                    statusCode: (response as? HTTPURLResponse)?.statusCode
                ))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        observedTask?.resume()
    }

    override func stopLoading() {
        observedTask?.cancel()
    }

    private func makeRecord(
        state: NectoNetworkRecord.State,
        statusCode: Int? = nil,
        error: (any Error)? = nil
    ) -> NectoNetworkRecord {
        let responseHeaders = httpResponse?.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String { result[key] = String(describing: entry.value) }
        } ?? [:]

        return NectoNetworkRecord(
            id: recordID,
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            startedAtMilliseconds: startedAt.timeIntervalSince1970 * 1000,
            state: state,
            statusCode: statusCode,
            durationMilliseconds: state == .pending
                ? nil
                : Date().timeIntervalSince(startedAt) * 1000,
            responseByteCount: state == .completed ? received : nil,
            errorSummary: error.map { String(describing: $0) },
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            responseHeaders: responseHeaders,
            // A pending record carries no body yet: the request one is already known,
            // but sending it twice would double the traffic for large uploads.
            requestBody: state == .pending ? nil : requestBodyData.map {
                NectoNetworkRecord.Body(
                    data: $0,
                    contentType: request.value(forHTTPHeaderField: "Content-Type")
                )
            },
            responseBody: state == .completed && !responseData.isEmpty
                ? NectoNetworkRecord.Body(
                    data: responseData,
                    contentType: httpResponse?.value(forHTTPHeaderField: "Content-Type")
                )
                : nil
        )
    }

    /// `httpBody` is nil when the caller used a stream, so fall back to draining it.
    private var requestBodyData: Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable, data.count < NectoNetworkRecord.Body.captureLimit {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
