//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing
@testable import NectoMacService

@Suite("Public app updates")
struct NectoAppReleaseTests {
    private func metadata() -> [String: Any] {
        [
            "tag_name": "0.4.3", "draft": false, "prerelease": false,
            "assets": ["Necto-0.4.3.dmg"].map {
                ["name": $0, "size": 64, "digest": "sha256:" + String(repeating: "a1", count: 32),
                 "browser_download_url": "https://github.com/toss/toss-necto/releases/download/0.4.3/\($0)"] as [String: Any]
            },
        ]
    }

    @Test("accepts a DMG-only release with GitHub's SHA-256 digest")
    func exactAssets() throws {
        let release = try NectoAppRelease(data: JSONSerialization.data(withJSONObject: metadata()))
        #expect(release.version.description == "0.4.3")
        #expect(release.imageURL.lastPathComponent == "Necto-0.4.3.dmg")
        #expect(release.imageSHA256 == String(repeating: "a1", count: 32))
    }

    @Test("rejects unsafe or ambiguous release metadata", arguments: ["missing", "duplicate", "url", "large", "negative", "zero", "draft", "prerelease", "tag"])
    func refusesMetadata(kind: String) throws {
        var object = metadata()
        var assets = try #require(object["assets"] as? [[String: Any]])
        switch kind {
        case "missing": assets.removeLast()
        case "duplicate": assets.append(assets[0])
        case "url": assets[0]["browser_download_url"] = "https://example.com/Necto-0.4.3.dmg"
        case "large": assets[0]["size"] = Int.max
        case "negative": assets[0]["size"] = -1
        case "zero": assets[0]["size"] = 0
        case "tag": object["tag_name"] = "../../other"
        default: object[kind] = true
        }
        object["assets"] = assets
        #expect(throws: (any Error).self) { try NectoAppRelease(data: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test("refuses missing or malformed digests without falling back to checksum files", arguments: [
        "missing", "null", "", "sha512:" + String(repeating: "a", count: 128),
        "sha256:" + String(repeating: "a", count: 63), "sha256:" + String(repeating: "a", count: 65),
        "sha256:" + String(repeating: "g", count: 64), "sha256:" + String(repeating: "a", count: 64) + "\n",
    ])
    func refusesDigest(_ digest: String) throws {
        var object = metadata()
        var assets = try #require(object["assets"] as? [[String: Any]])
        if digest == "missing" { assets[0].removeValue(forKey: "digest") }
        else if digest == "null" { assets[0]["digest"] = NSNull() }
        else { assets[0]["digest"] = digest }
        assets.append(["name": "Necto-0.4.3.dmg.sha256", "size": 65,
                       "browser_download_url": "https://github.com/toss/toss-necto/releases/download/0.4.3/Necto-0.4.3.dmg.sha256"])
        object["assets"] = assets
        #expect(throws: NectoAppRelease.Failure.invalidRelease) {
            try NectoAppRelease(data: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("normalizes hexadecimal case and ignores unrelated release assets")
    func uppercaseDigest() throws {
        var object = metadata()
        var assets = try #require(object["assets"] as? [[String: Any]])
        assets[0]["digest"] = "sha256:" + String(repeating: "AB", count: 32)
        assets.append(["name": "notes.txt", "size": 1, "browser_download_url": "https://example.com/notes.txt"])
        object["assets"] = assets
        let release = try NectoAppRelease(data: JSONSerialization.data(withJSONObject: object))
        #expect(release.imageSHA256 == String(repeating: "ab", count: 32))
    }

    @Test("rejects redirect host confusion and transport downgrades", arguments: [
        "http://github.com/file", "https://github.com.evil.test/file", "https://github.com@evil.test/file",
        "https://user:password@github.com/file", "https://github.com:8443/file", "file:///tmp/app.dmg",
    ])
    func refusesRedirects(text: String) throws {
        #expect(!NectoAppRelease.permitsDownloadURL(try #require(URL(string: text))))
    }

    @Test("verifies downloaded bytes against the API digest", arguments: ["valid", "modified", "missing"])
    func imageChecksum(kind: String) async throws {
        var object = metadata()
        var assets = try #require(object["assets"] as? [[String: Any]])
        assets[0]["digest"] = "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        object["assets"] = assets
        let release = try NectoAppRelease(data: JSONSerialization.data(withJSONObject: object))
        let file = FileManager.default.temporaryDirectory.appending(path: "necto-digest-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: file) }
        if kind != "missing" { try Data((kind == "valid" ? "test" : "changed").utf8).write(to: file) }
        if kind == "valid" { try await release.verifyImageChecksum(at: file) }
        else {
            await #expect(throws: NectoAppRelease.Failure.checksumMismatch) {
                try await release.verifyImageChecksum(at: file)
            }
        }
    }

    @Test("allows GitHub's HTTPS asset redirect")
    func allowsAssetRedirect() throws {
        #expect(NectoAppRelease.permitsDownloadURL(try #require(URL(string: "https://release-assets.githubusercontent.com/file?token=example"))))
    }

    @Test("requires the same app and the exact newer version", arguments: ["valid", "identifier", "version", "downgrade", "missing"])
    func applicationMetadata(kind: String) throws {
        var installed: [String: Any] = ["CFBundleIdentifier": "im.toss.necto", "CFBundleShortVersionString": "0.4.2"]
        var candidate: [String: Any] = ["CFBundleIdentifier": "im.toss.necto", "CFBundleShortVersionString": "0.4.3"]
        switch kind {
        case "identifier": candidate["CFBundleIdentifier"] = "im.example.other"
        case "version": candidate["CFBundleShortVersionString"] = "0.4.4"
        case "downgrade": installed["CFBundleShortVersionString"] = "0.4.4"
        case "missing": installed.removeValue(forKey: "CFBundleIdentifier")
        default: break
        }
        let version = try #require(NectoSemanticVersion("0.4.3"))
        if kind == "valid" {
            try NectoUpdateValidation.validateMetadata(installed: installed, candidate: candidate, expectedVersion: version)
        } else {
            #expect(throws: (any Error).self) {
                try NectoUpdateValidation.validateMetadata(installed: installed, candidate: candidate, expectedVersion: version)
            }
        }
    }

    @Test("ad-hoc updates preserve integrity checks", arguments: ["valid", "resource", "cli", "unsigned", "missing"])
    func adHocUpdate(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "necto-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try await makeApp(at: root.appending(path: "installed.app"), version: "0.4.2")
        let candidate = try await makeApp(at: root.appending(path: "candidate.app"), version: "0.4.3")
        switch kind {
        case "resource":
            try Data("changed".utf8).write(to: candidate.appending(path: "Contents/Resources/sample.txt"))
        case "cli":
            try await codesign(["--remove-signature", candidate.appending(path: "Contents/MacOS/necto-cli").path])
        case "unsigned":
            try await codesign(["--remove-signature", candidate.path])
        case "missing":
            try FileManager.default.removeItem(at: candidate)
        default: break
        }
        let version = try #require(NectoSemanticVersion("0.4.3"))
        if kind == "valid" {
            try await NectoUpdateValidation.verify(candidate: candidate, installed: installed, expectedVersion: version)
        } else if kind == "missing" {
            await #expect(throws: (any Error).self) {
                try await NectoUpdateValidation.verify(candidate: candidate, installed: installed, expectedVersion: version)
            }
        } else {
            await #expect(throws: NectoUpdateValidation.Failure.invalidSignature) {
                try await NectoUpdateValidation.verify(candidate: candidate, installed: installed, expectedVersion: version)
            }
        }
    }

    private func makeApp(at app: URL, version: String) async throws -> URL {
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "im.toss.necto.test", "CFBundleExecutable": "Necto",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try Data("original".utf8).write(to: contents.appending(path: "Resources/sample.txt"))
        for name in ["Necto", "necto-cli"] {
            let executable = contents.appending(path: "MacOS/\(name)")
            try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
            try await codesign(["--force", "--sign", "-", "--timestamp=none", executable.path])
        }
        try await codesign(["--force", "--sign", "-", "--timestamp=none", app.path])
        return app
    }

    private func codesign(_ arguments: [String]) async throws {
        let result = try await NectoProcessRunner.run(
            "/usr/bin/codesign", arguments: arguments
        )
        try #require(result.exitCode == 0)
    }
}
