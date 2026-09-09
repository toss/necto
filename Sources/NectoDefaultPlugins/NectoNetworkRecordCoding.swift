//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// How a record travels. The shape here is the one the manifest declares a schema for,
/// so the two move together.
public enum NectoNetworkRecordCoding {
    /// What a row needs. Bodies are deliberately absent: a list of five hundred
    /// requests should not carry five hundred response bodies with it.
    public static func summary(_ record: NectoNetworkRecord) -> NectoJSONValue {
        var object: [String: NectoJSONValue] = [
            "id": .string(record.id),
            "method": .string(record.method),
            "url": .string(record.url),
            "name": .string(record.name),
            "host": .string(record.host),
            "state": .string(record.state.rawValue),
            "startedAtMilliseconds": .number(record.startedAtMilliseconds),
        ]
        if let statusCode = record.statusCode {
            object["statusCode"] = .number(Double(statusCode))
        }
        if let duration = record.durationMilliseconds {
            object["durationMilliseconds"] = .number(duration)
        }
        if let bytes = record.responseByteCount {
            object["responseByteCount"] = .number(Double(bytes))
        }
        if let error = record.errorSummary {
            object["errorSummary"] = .string(error)
        }
        return .object(object)
    }

    /// The summary plus everything a detail pane shows.
    public static func detail(_ record: NectoNetworkRecord) -> NectoJSONValue {
        guard var object = summary(record).objectValue else { return summary(record) }

        object["requestHeaders"] = headers(record.requestHeaders)
        object["responseHeaders"] = headers(record.responseHeaders)
        object["curl"] = .string(curl(record))
        if let body = record.requestBody {
            object["requestBody"] = self.body(body)
        }
        if let body = record.responseBody {
            object["responseBody"] = self.body(body)
        }
        return .object(object)
    }

    private static func headers(_ headers: [String: String]) -> NectoJSONValue {
        .object(headers.mapValues { .string($0) })
    }

    private static func body(_ body: NectoNetworkRecord.Body) -> NectoJSONValue {
        var object: [String: NectoJSONValue] = [
            "byteCount": .number(Double(body.byteCount)),
            "isTruncated": .bool(body.isTruncated),
        ]
        if let contentType = body.contentType {
            object["contentType"] = .string(contentType)
        }
        if let text = body.text {
            object["text"] = .string(text)
        }
        return .object(object)
    }

    /// A command the developer can paste into a terminal to repeat the request.
    private static func curl(_ record: NectoNetworkRecord) -> String {
        var parts = ["curl -X \(record.method)", "'\(record.url)'"]

        for key in record.requestHeaders.keys.sorted() {
            let value = record.requestHeaders[key] ?? ""
            parts.append("-H '\(key): \(escaped(value))'")
        }
        if let text = record.requestBody?.text {
            parts.append("--data-raw '\(escaped(text))'")
        }
        return parts.joined(separator: " \\\n  ")
    }

    /// A quote inside a single-quoted shell argument has to close and reopen it.
    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}
