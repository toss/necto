//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// Public app updates have a fixed source and never borrow a plugin's gh login.
public struct NectoAppRelease: Sendable {
    public static let repository = "toss/necto"
    public static let pageURL = URL(string: "https://github.com/\(repository)/releases")!
    public let version: NectoSemanticVersion
    public let imageURL: URL
    public let imageSHA256: String
    private static let maximumImageBytes = 512 * 1_048_576

    public static func latest() async throws -> Self {
        let version = try await latestVersion(at: pageURL.appending(path: "latest"))
        let imageURL = imageURL(for: version)
        do {
            let file = try await download(imageURL.appendingPathExtension("sha256"), maximumBytes: 256)
            defer { try? FileManager.default.removeItem(at: file) }
            return try Self(version: version, checksum: Data(contentsOf: file))
        } catch Failure.downloadFailed(let status) {
            throw Failure.checkFailed(status)
        }
    }

    static func latestVersion(at url: URL) async throws -> NectoSemanticVersion {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: ReleaseRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Necto", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode < 400 else { throw Failure.checkFailed(response.statusCode) }
        guard response.statusCode == 302,
              let location = response.value(forHTTPHeaderField: "Location"),
              let releaseURL = URL(string: location) else { throw Failure.invalidRelease }
        return try version(from: releaseURL)
    }

    static func version(from releaseURL: URL) throws -> NectoSemanticVersion {
        let tag = releaseURL.lastPathComponent
        guard let version = NectoSemanticVersion(tag), version.prerelease == nil, version.build == nil,
              releaseURL.absoluteString == "\(pageURL.absoluteString)/tag/\(version)" else {
            throw Failure.invalidRelease
        }
        return version
    }

    private static func imageURL(for version: NectoSemanticVersion) -> URL {
        pageURL.appending(path: "download/\(version)/Necto-\(version).dmg")
    }

    init(version: NectoSemanticVersion, checksum: Data) throws {
        let imageURL = Self.imageURL(for: version)
        guard let text = String(data: checksum, encoding: .utf8) else { throw Failure.invalidRelease }
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let suffix = "  \(imageURL.lastPathComponent)"
        guard line.hasSuffix(suffix) else { throw Failure.invalidRelease }
        let hash = String(line.dropLast(suffix.count)).lowercased()
        guard hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidRelease
        }
        self.version = version
        self.imageURL = imageURL
        imageSHA256 = hash
    }

    public func downloadImage(into directory: URL) async throws -> URL {
        let image = try await Self.download(imageURL, maximumBytes: Self.maximumImageBytes)
        defer { try? FileManager.default.removeItem(at: image) }
        try Task.checkCancellation()
        let destination = directory.appending(path: imageURL.lastPathComponent)
        try FileManager.default.moveItem(at: image, to: destination)
        return destination
    }

    public func verifyImageChecksum(at image: URL) async throws {
        let output = try await NectoProcessRunner.run("/usr/bin/shasum", arguments: ["-a", "256", image.path])
        let digest = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace).first
        guard output.exitCode == 0, let digest, digest == imageSHA256 else { throw Failure.checksumMismatch }
    }

    static func download(_ url: URL, maximumBytes: Int) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        var request = URLRequest(url: url)
        request.setValue("Necto", forHTTPHeaderField: "User-Agent")
        return try await Download(maximumBytes: maximumBytes).run(request, configuration: configuration)
    }

    static func permitsDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
            .contains(url.host?.lowercased() ?? "")
    }

    private final class ReleaseRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // Read the tag from Location without downloading or parsing a release page.
            completionHandler(nil)
        }
    }

    private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let maximumBytes: Int
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, any Error>?
        private var session: URLSession?
        private var task: URLSessionDownloadTask?
        private var downloaded: URL?
        private var failure: (any Error)?
        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> URL {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let file: URL = try await withCheckedThrowingContinuation { continuation in
                    lock.withLock {
                        if let failure { continuation.resume(throwing: failure); return }
                        self.continuation = continuation
                        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                        self.session = session
                        let task = session.downloadTask(with: request)
                        self.task = task
                        task.resume()
                    }
                }
                do { try Task.checkCancellation(); return file }
                catch { try? FileManager.default.removeItem(at: file); throw error }
            } onCancel: {
                self.cancel(CancellationError())
            }
        }

        private func cancel(_ error: any Error) {
            let task = lock.withLock {
                if failure == nil { failure = error }
                return self.task
            }
            task?.cancel()
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { cancel(Failure.tooLarge) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw Failure.downloadFailed((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= maximumBytes else { throw Failure.tooLarge }
                guard size > 0 else { throw Failure.invalidRelease }
                // The delegate's temporary URL is only valid until this callback returns.
                let file = FileManager.default.temporaryDirectory.appending(path: "necto-download-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: location, to: file)
                lock.withLock { downloaded = file }
            } catch {
                cancel(error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let result = lock.withLock { () -> (CheckedContinuation<URL, any Error>?, URL?, (any Error)?) in
                defer {
                    continuation = nil
                    downloaded = nil
                    self.task = nil
                    self.session = nil
                }
                return (continuation, downloaded, failure ?? error)
            }
            session.finishTasksAndInvalidate()
            if let error = result.2 {
                if let file = result.1 { try? FileManager.default.removeItem(at: file) }
                result.0?.resume(throwing: error)
            } else if let file = result.1 {
                result.0?.resume(returning: file)
            } else {
                result.0?.resume(throwing: URLError(.badServerResponse))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url.map(NectoAppRelease.permitsDownloadURL) == true ? request : nil)
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidRelease
        case checksumMismatch
        case checkFailed(Int)
        case downloadFailed(Int)
        case tooLarge

        public var description: String {
            switch self {
            case .invalidRelease: "The release has invalid or missing app assets"
            case .checksumMismatch: "The download did not match its published hash"
            case let .checkFailed(status): "The update check failed (HTTP \(status))"
            case let .downloadFailed(status): "The update download failed (HTTP \(status))"
            case .tooLarge: "The update download exceeded its size limit"
            }
        }
    }
}
