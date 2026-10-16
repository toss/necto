//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import CryptoKit
import Foundation
import NectoMacService
import NectoModel
import UniformTypeIdentifiers
import WebKit

/// Serves checked assets under a host-owned origin scoped to the plugin principal.
final class NectoPluginSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "necto-plugin"

    private let originHost: String
    private let files: [String: Data]
    private let contentSecurityPolicy: String

    init(originHost: String, archive: NectoPanelArchive, allowedOrigins: [String] = ["self"]) {
        self.originHost = originHost
        let external = allowedOrigins.compactMap { value -> String? in
            guard let url = URLComponents(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
                  host.allSatisfy({ "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]".contains($0) }),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/",
                  url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
            return "https://" + host + (url.port.map { ":\($0)" } ?? "")
        }.joined(separator: " ")
        let local = "'self' " + external
        contentSecurityPolicy = "default-src \(local); connect-src \(local); "
            + "script-src \(local) 'unsafe-inline'; style-src \(local) 'unsafe-inline'; "
            + "img-src \(local) data: blob:; font-src \(local) data:; media-src \(local) blob:; "
            + "frame-src 'self'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        files = Dictionary(archive.files.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })
    }

    static func originHost(for principal: NectoPluginPrincipal) -> String {
        // Length-prefix both fields to avoid ambiguous joins. Content changes must
        // not change this origin; updates retain the principal's browser storage.
        let identity = "\(principal.sourceIdentity.utf8.count):\(principal.sourceIdentity)\(principal.pluginID.utf8.count):\(principal.pluginID)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digest.prefix(32)).\(digest.suffix(32))"
    }

    static func entryPointURL(originHost: String) -> URL? {
        URL(string: "\(scheme)://\(originHost)/index.html")
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == Self.scheme, url.host == originHost else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let path = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        guard let data = files[path] else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": Self.mimeType(for: URL(filePath: path)) + "; charset=utf-8",
            "Content-Security-Policy": contentSecurityPolicy,
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        ]) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}

    private static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
