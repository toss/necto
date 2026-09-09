//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// One network request observed inside a connected app.
///
/// A record is sent twice: once when the request starts, and once when it finishes.
/// The `id` is what ties them together, so the host can show a pending row and fill
/// it in rather than waiting for completion to show anything.
public struct NectoNetworkRecord: Sendable, Hashable, Codable, Identifiable {
    public enum State: String, Sendable, Codable {
        case pending
        case completed
        case failed
    }

    /// A captured body.
    ///
    /// Bodies are capped rather than streamed whole: a debugging tool has to stay
    /// usable on a large upload, and a body past the cap is rarely read in full.
    /// `text` is absent when the payload is binary, in which case size and type are
    /// still worth showing.
    public struct Body: Sendable, Hashable, Codable {
        /// Bodies beyond this are cut, with `isTruncated` set.
        public static let captureLimit = 512 * 1024

        public let byteCount: Int
        public let isTruncated: Bool
        public let contentType: String?
        public let text: String?

        public init(byteCount: Int, isTruncated: Bool, contentType: String?, text: String?) {
            self.byteCount = byteCount
            self.isTruncated = isTruncated
            self.contentType = contentType
            self.text = text
        }

        /// Captures a body, keeping text when it decodes and the type looks textual.
        public init(data: Data, contentType: String?) {
            byteCount = data.count
            self.contentType = contentType

            let capped = data.prefix(Self.captureLimit)
            isTruncated = data.count > Self.captureLimit
            text = Self.looksTextual(contentType) ? String(data: capped, encoding: .utf8) : nil
        }

        private static func looksTextual(_ contentType: String?) -> Bool {
            guard let contentType = contentType?.lowercased() else { return true }
            return contentType.contains("json")
                || contentType.contains("text")
                || contentType.contains("xml")
                || contentType.contains("javascript")
                || contentType.contains("x-www-form-urlencoded")
        }
    }

    public let id: String
    public let method: String
    public let url: String
    public let startedAtMilliseconds: Double
    public let state: State
    public let statusCode: Int?
    public let durationMilliseconds: Double?
    public let responseByteCount: Int?
    public let errorSummary: String?
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let requestBody: Body?
    public let responseBody: Body?

    public init(
        id: String,
        method: String,
        url: String,
        startedAtMilliseconds: Double,
        state: State,
        statusCode: Int? = nil,
        durationMilliseconds: Double? = nil,
        responseByteCount: Int? = nil,
        errorSummary: String? = nil,
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        requestBody: Body? = nil,
        responseBody: Body? = nil
    ) {
        self.id = id
        self.method = method
        self.url = url
        self.startedAtMilliseconds = startedAtMilliseconds
        self.state = state
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
        self.responseByteCount = responseByteCount
        self.errorSummary = errorSummary
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
    }

    /// The last path segment, which is what identifies a request when scanning a list.
    /// Hosts differ far less often than paths do.
    public var name: String {
        guard let components = URLComponents(string: url) else { return url }
        let last = components.path.split(separator: "/").last.map(String.init) ?? components.host ?? url
        guard let query = components.query else { return last }
        return "\(last)?\(query)"
    }

    public var host: String {
        URLComponents(string: url)?.host ?? ""
    }
}
