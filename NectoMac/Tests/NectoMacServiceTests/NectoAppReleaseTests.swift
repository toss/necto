//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing
@testable import NectoMacService

@Suite("Public app updates")
struct NectoAppReleaseTests {
    private func release(version: String = "0.4.3", hash: String = String(repeating: "a1", count: 32)) throws -> NectoAppRelease {
        try NectoAppRelease(
            version: #require(NectoSemanticVersion(version)),
            checksum: Data("\(hash)  Necto-\(version).dmg\n".utf8)
        )
    }

    @Test("pins the DMG and checksum to the discovered version", arguments: ["0.1.0", "0.1.1", "0.4.3"])
    func exactAssets(version: String) throws {
        #expect(NectoAppRelease.repository == "toss/necto")
        #expect(NectoAppRelease.pageURL.absoluteString == "https://github.com/toss/necto/releases")
        let tagURL = try #require(URL(string: "https://github.com/toss/necto/releases/tag/\(version)"))
        #expect(try NectoAppRelease.version(from: tagURL).description == version)
        let release = try release(version: version)
        #expect(release.version.description == version)
        #expect(release.imageURL.absoluteString == "https://github.com/toss/necto/releases/download/\(version)/Necto-\(version).dmg")
        #expect(release.imageSHA256 == String(repeating: "a1", count: 32))
    }

    @Test("rejects unexpected release locations", arguments: [
        "https://github.com/toss/toss-necto/releases/tag/0.1.0",
        "https://github.com/other/necto/releases/tag/0.1.0",
        "https://github.com/toss/necto/releases/latest",
        "https://github.com/toss/necto/releases/tag/v0.1.0",
        "https://github.com/toss/necto/releases/tag/0.1.0-beta.1",
        "https://github.com/toss/necto/releases/tag/0.1.0+build.1",
        "https://github.com/toss/necto/releases/tag/00.1.0",
        "https://github.com/toss/necto/releases/tag/0.1.0/",
        "https://github.com/toss/necto/releases/tag/%30.1.0",
        "https://github.com/toss/necto/releases/tag/0.1.0?download=1",
        "https://github.com/toss/necto/releases/tag/0.1.0#fragment",
        "https://github.com/toss/necto/releases/tag/../0.1.0",
        "https://github.com.evil.test/toss/necto/releases/tag/0.1.0",
        "https://user:password@github.com/toss/necto/releases/tag/0.1.0",
        "http://github.com/toss/necto/releases/tag/0.1.0",
        "https://github.com:8443/toss/necto/releases/tag/0.1.0",
    ])
    func refusesLocations(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(throws: NectoAppRelease.Failure.invalidRelease) { try NectoAppRelease.version(from: url) }
    }

    @Test("refuses malformed or wrong-file checksums", arguments: [
        "", String(repeating: "a", count: 63) + "  Necto-0.4.3.dmg\n",
        String(repeating: "a", count: 65) + "  Necto-0.4.3.dmg\n",
        String(repeating: "g", count: 64) + "  Necto-0.4.3.dmg\n",
        String(repeating: "a", count: 64) + "  Necto-0.4.4.dmg\n",
        String(repeating: "a", count: 64) + "  Build/Necto-0.4.3.dmg\n",
        String(repeating: "a", count: 64) + "  Necto-0.4.3.dmg\n\n",
        String(repeating: "a", count: 64) + "  Necto-0.4.3.dmg\nextra",
        String(repeating: "a", count: 64),
    ])
    func refusesDigest(_ text: String) throws {
        let version = try #require(NectoSemanticVersion("0.4.3"))
        #expect(throws: NectoAppRelease.Failure.invalidRelease) {
            try NectoAppRelease(version: version, checksum: Data(text.utf8))
        }
    }

    @Test("normalizes hexadecimal case")
    func uppercaseDigest() throws {
        let release = try release(hash: String(repeating: "AB", count: 32))
        #expect(release.imageSHA256 == String(repeating: "ab", count: 32))
    }

    @Test("only offers newer versions, including after the public version reset", arguments: [
        ("0.1.0", "0.1.1", true), ("0.1.1", "0.1.1", false),
        ("0.1.2", "0.1.1", false), ("0.4.2", "0.1.0", false),
        ("0.1.9", "0.1.10", true),
    ])
    func newerVersion(current: String, latest: String, expected: Bool) throws {
        let installed = try #require(NectoSemanticVersion(current))
        let url = try #require(URL(string: "https://github.com/toss/necto/releases/tag/\(latest)"))
        #expect(try (NectoAppRelease.version(from: url) > installed) == expected)
    }

    @Test("rejects redirect host confusion and transport downgrades", arguments: [
        "http://github.com/file", "https://github.com.evil.test/file", "https://github.com@evil.test/file",
        "https://user:password@github.com/file", "https://github.com:8443/file", "file:///tmp/app.dmg",
    ])
    func refusesRedirects(text: String) throws {
        #expect(!NectoAppRelease.permitsDownloadURL(try #require(URL(string: text))))
    }

    @Test("verifies downloaded bytes against the published checksum", arguments: ["valid", "modified", "missing"])
    func imageChecksum(kind: String) async throws {
        let release = try release(hash: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
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
