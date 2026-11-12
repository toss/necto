//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoNetworkPlugin

final class NectoSessionRecorder: @unchecked Sendable {
    static let shared = NectoSessionRecorder()
    private let lock = NSLock()
    private var reporter: (any NectoNetworkReporting)?
    private let entries = NSMapTable<URLSessionTask, Entry>.weakToStrongObjects()

    private final class Entry {
        let id = UUID().uuidString
        let request: URLRequest
        var started: Date?
        var finished = false
        var requestBody: NectoNetworkRecord.Body?
        var response: HTTPURLResponse?
        var data = Data()
        var received = 0

        init(request: URLRequest, body: Data?) {
            self.request = request
            // Never consume an application's body stream to obtain a preview.
            requestBody = (body ?? request.httpBody).map {
                NectoNetworkRecord.Body(data: $0, contentType: request.value(forHTTPHeaderField: "Content-Type"))
            }
        }

        func record(error: Error? = nil) -> NectoNetworkRecord {
            let started = started ?? Date()
            let body = NectoNetworkRecord.Body(data: data, contentType: response?.value(forHTTPHeaderField: "Content-Type"))
            return NectoNetworkRecord(
                id: id, method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "",
                startedAtMilliseconds: started.timeIntervalSince1970 * 1000,
                state: finished ? (error == nil ? .completed : .failed) : .pending,
                statusCode: finished ? response?.statusCode : nil,
                durationMilliseconds: finished ? Date().timeIntervalSince(started) * 1000 : nil,
                responseByteCount: finished ? received : nil,
                errorSummary: error.map { String(describing: $0) },
                requestHeaders: request.allHTTPHeaderFields ?? [:],
                responseHeaders: response?.allHeaderFields.reduce(into: [:]) { result, entry in
                    if let key = entry.key as? String { result[key] = String(describing: entry.value) }
                } ?? [:],
                requestBody: finished ? requestBody : nil,
                responseBody: finished && received > 0
                    ? .init(byteCount: received, isTruncated: received > NectoNetworkRecord.Body.captureLimit,
                            contentType: body.contentType, text: body.text) : nil
            )
        }
    }

    func install(_ reporter: any NectoNetworkReporting) {
        lock.withLock { self.reporter = reporter; entries.removeAllObjects() }
    }

    func uninstall() {
        lock.withLock { reporter = nil; entries.removeAllObjects() }
    }

    func prepare(_ task: URLSessionTask, request: URLRequest, body: Data? = nil) {
        lock.withLock {
            guard reporter != nil, entries.object(forKey: task) == nil,
                  ["http", "https"].contains(request.url?.scheme) else { return }
            entries.setObject(Entry(request: request, body: body), forKey: task)
        }
    }

    func resume(_ task: URLSessionTask) {
        let event = lock.withLock { () -> ((any NectoNetworkReporting), NectoNetworkRecord)? in
            guard let reporter, !(task is URLSessionWebSocketTask),
                  let request = task.originalRequest ?? task.currentRequest,
                  ["http", "https"].contains(request.url?.scheme) else { return nil }
            let entry = entries.object(forKey: task) ?? Entry(request: request, body: nil)
            guard entry.started == nil, !entry.finished else { return nil }
            entry.started = Date()
            entries.setObject(entry, forKey: task)
            return (reporter, entry.record())
        }
        if let (reporter, record) = event { reporter.report(record) }
    }

    func receive(_ task: URLSessionTask, data: Data? = nil, response: URLResponse? = nil) {
        lock.withLock {
            guard reporter != nil, let entry = entries.object(forKey: task), !entry.finished else { return }
            if let response = response as? HTTPURLResponse { entry.response = response }
            if let data {
                entry.received += data.count
                let room = NectoNetworkRecord.Body.captureLimit + 1 - entry.data.count
                if room > 0 { entry.data.append(data.prefix(room)) }
            }
        }
    }

    func complete(_ task: URLSessionTask, error: Error?) {
        let event = lock.withLock { () -> ((any NectoNetworkReporting), NectoNetworkRecord)? in
            guard let reporter, let entry = entries.object(forKey: task), !entry.finished,
                  entry.started != nil else { return nil }
            entry.finished = true
            entry.response = (task.response as? HTTPURLResponse) ?? entry.response
            let record = entry.record(error: error)
            entry.data = Data()
            entry.requestBody = nil
            return (reporter, record)
        }
        if let (reporter, record) = event { reporter.report(record) }
    }
}
