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

    init(originHost: String, archive: NectoPanelArchive) {
        self.originHost = originHost
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

        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(for: URL(filePath: path)),
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
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
