//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// Public app updates have a fixed source and never borrow a plugin's gh login.
public struct NectoAppRelease: Sendable {
    public static let repository = "toss/toss-necto"
    public static let pageURL = URL(string: "https://github.com/\(repository)/releases")!
    public let version: NectoSemanticVersion
    public let imageURL: URL
    public let imageSHA256: String
    private static let maximumImageBytes = 512 * 1_048_576

    public static func latest() async throws -> Self {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let file = try await download(url, maximumBytes: 1_048_576)
        defer { try? FileManager.default.removeItem(at: file) }
        return try Self(data: Data(contentsOf: file))
    }

    init(data: Data) throws {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
            let digest: String?
        }
        struct Metadata: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard !metadata.draft, !metadata.prerelease,
              let version = NectoSemanticVersion(metadata.tag_name), metadata.tag_name == version.description else {
            throw Failure.invalidRelease
        }
        func asset(_ name: String, limit: Int) throws -> Asset {
            let matches = metadata.assets.filter { $0.name == name }
            guard matches.count == 1, let asset = matches.first,
                  asset.size > 0, asset.size <= limit,
                  asset.browser_download_url.absoluteString == "https://github.com/\(Self.repository)/releases/download/\(version)/\(name)" else {
                throw Failure.invalidRelease
            }
            return asset
        }
        let image = try asset("Necto-\(version).dmg", limit: Self.maximumImageBytes)
        guard let digest = image.digest, digest.hasPrefix("sha256:") else { throw Failure.invalidRelease }
        let hash = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidRelease
        }
        self.version = version
        imageURL = image.browser_download_url
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
        return ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
            .contains(url.host?.lowercased() ?? "")
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
        case downloadFailed(Int)
        case tooLarge

        public var description: String {
            switch self {
            case .invalidRelease: "The release has invalid or missing app assets"
            case .checksumMismatch: "The download did not match its published hash"
            case let .downloadFailed(status): "The update download failed (HTTP \(status))"
            case .tooLarge: "The update download exceeded its size limit"
            }
        }
    }
}
