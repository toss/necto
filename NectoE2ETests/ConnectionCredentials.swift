//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import NectoTransport
import Security
import Testing

enum ConnectionSecurity: String, CaseIterable {
    case plaintext, matchingKey, missingKey, mismatchedKey
}

@MainActor
final class ConnectionCredentials {
    let publicKey: String?
    let directory: URL
    private let keychain: SecKeychain
    private let material: (key: Data, certificate: Data)?
    private(set) var lookups: [String] = []

    init(security: ConnectionSecurity) throws {
        SecKeychainSetUserInteractionAllowed(false)
        let directory = FileManager.default.temporaryDirectory.appending(path: "necto-security-e2e-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let path = directory.appending(path: "connection.keychain-db").path
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &created)
        }
        guard status == errSecSuccess, let created else {
            try? FileManager.default.removeItem(at: directory)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        keychain = created
        do {
            if security == .plaintext {
                material = nil
                publicKey = nil
            } else {
                let generated = try Self.generate(in: directory)
                material = generated
                let certificate = try #require(SecCertificateCreateWithData(nil, generated.certificate as CFData))
                let key = try #require(SecCertificateCopyKey(certificate))
                publicKey = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?).base64EncodedString()
            }
            if security == .matchingKey {
                try installMatchingKey()
            } else if security == .mismatchedKey {
                let other = try Self.generate(in: directory)
                try install(other)
            }
        } catch {
            SecKeychainDelete(keychain)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func installMatchingKey() throws {
        try install(try #require(material))
    }

    func identity(bundleID: String) throws -> NectoTLSIdentity? {
        lookups.append(bundleID)
        return try NectoKeychainCredentialStore(keychain: keychain).identity(bundleID: bundleID)
    }

    private func install(_ material: (key: Data, certificate: Data)) throws {
        try NectoKeychainCredentialStore(keychain: keychain).install(
            bundleID: AppFixture.exampleID, privateKeyPEM: material.key,
            certificateDER: material.certificate
        )
    }

    func close() {
        #expect(SecKeychainDelete(keychain) == errSecSuccess)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func generate(in directory: URL) throws -> (key: Data, certificate: Data) {
        let key = directory.appending(path: UUID().uuidString + ".pem")
        let certificate = directory.appending(path: UUID().uuidString + ".der")
        defer {
            try? FileManager.default.removeItem(at: key)
            try? FileManager.default.removeItem(at: certificate)
        }
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try openssl(["req", "-new", "-x509", "-key", key.path, "-subj", "/CN=Necto-E2E", "-days", "1", "-outform", "DER", "-out", certificate.path])
        return try (Data(contentsOf: key), Data(contentsOf: certificate))
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}
