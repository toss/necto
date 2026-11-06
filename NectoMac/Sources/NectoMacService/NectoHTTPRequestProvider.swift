//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import os

/// Executes a plugin's HTTPS request on the Mac, outside the WebView's CORS policy.
public final class NectoHTTPRequestProvider: NectoOperationProvider {
    public static let key = "necto.desktop.http.request"

    public let descriptor = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: key, version: 1),
        kind: .once
    )

    private let session: URLSession

    public convenience init() {
        self.init(configuration: .ephemeral)
    }

    init(configuration: URLSessionConfiguration) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // The registry owns each operation's deadline and cancels only its task.
        configuration.timeoutIntervalForRequest = .greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func invoke(input: NectoJSONValue, context _: NectoInvocationContext) async throws -> NectoJSONValue {
        let request = try Self.request(from: input)
        let redirects = HTTPSRedirects()

        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request, delegate: redirects)
            try Task.checkCancellation()
            guard !redirects.rejected.withLock({ $0 }) else {
                throw NectoBridgeError(code: .providerFailed, message: "The server redirected to a non-HTTPS URL")
            }
            guard let response = response as? HTTPURLResponse else {
                throw NectoBridgeError(code: .providerFailed, message: "The server did not return an HTTP response")
            }
            var headers: [String: NectoJSONValue] = [:]
            for (name, value) in response.allHeaderFields {
                if let name = name as? String {
                    headers[name] = .string(String(describing: value))
                }
            }
            return [
                "status": .number(Double(response.statusCode)),
                "headers": .object(headers),
                "bodyBase64": .string(data.base64EncodedString()),
            ]
        } catch is CancellationError {
            throw NectoBridgeError(code: .cancelled, message: "The HTTP request was cancelled")
        } catch let error as URLError {
            let code: NectoBridgeErrorCode
            switch error.code {
            case .cancelled: code = .cancelled
            case .timedOut: code = .timeout
            default: code = .providerFailed
            }
            // Foundation error descriptions may contain the URL or authentication details.
            throw NectoBridgeError(
                code: code,
                message: "The HTTP request failed",
                details: ["urlErrorCode": .number(Double(error.errorCode))]
            )
        } catch let error as NectoBridgeError {
            throw error
        } catch {
            throw NectoBridgeError(code: .providerFailed, message: "The HTTP request failed")
        }
    }

    private static func request(from input: NectoJSONValue) throws -> URLRequest {
        guard let rawURL = input["url"]?.stringValue,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            throw NectoBridgeError(code: .invalidInput, message: "url must be an absolute HTTPS URL")
        }
        guard let method = input["method"]?.stringValue, isValidHTTPToken(method) else {
            throw NectoBridgeError(code: .invalidInput, message: "method must be a non-empty HTTP token")
        }
        var request = URLRequest(url: url, timeoutInterval: .greatestFiniteMagnitude)
        request.httpShouldHandleCookies = false
        request.httpMethod = method
        if let value = input["headers"] {
            guard let headers = value.objectValue else {
                throw NectoBridgeError(code: .invalidInput, message: "headers must be an object of strings")
            }
            for (name, value) in headers {
                guard isValidHTTPToken(name), let text = value.stringValue,
                      text.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
                    throw NectoBridgeError(
                        code: .invalidInput,
                        message: "headers must contain valid HTTP names and string values"
                    )
                }
                request.setValue(text, forHTTPHeaderField: name)
            }
        }
        if let value = input["bodyBase64"] {
            guard let text = value.stringValue, let data = Data(base64Encoded: text) else {
                throw NectoBridgeError(code: .invalidInput, message: "bodyBase64 must contain valid Base64 data")
            }
            request.httpBody = data
        }
        return request
    }

    private static func isValidHTTPToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }

    private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        let rejected = OSAllocatedUnfairLock(initialState: false)

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard request.url?.scheme?.lowercased() == "https" else {
                rejected.withLock { $0 = true }
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
