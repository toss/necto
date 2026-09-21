//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Security
import Testing
@testable import NectoMacService
@testable import NectoTransport

@Suite("Keychain credentials", .serialized, .timeLimit(.minutes(1)))
struct CredentialTests {
    private func certificateReference(_ fixture: CredentialFixture, bundleID: String) throws -> Data {
        var result: CFTypeRef?
        try #require(SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: "im.necto.connection.certificate",
            kSecAttrAccount: bundleID, kSecMatchSearchList: [fixture.keychain], kSecReturnAttributes: true,
        ] as CFDictionary, &result) == errSecSuccess)
        return try #require((result as? [CFString: Any])?[kSecAttrGeneric] as? Data)
    }

    @Test("a missing certificate fails closed rather than selecting another stored identity")
    func missingCertificate() throws {
        let fixture = try CredentialFixture()
        let reference = try certificateReference(fixture, bundleID: CredentialFixture.bundleID)
        #expect(SecItemDelete([
            kSecClass: kSecClassCertificate, kSecMatchItemList: [reference],
            kSecMatchSearchList: [fixture.keychain],
        ] as CFDictionary) == errSecSuccess)
        #expect(throws: (any Error).self) { _ = try fixture.store.identity(bundleID: CredentialFixture.bundleID) }
        #expect(SecKeyCreateSignature(fixture.identity.privateKey, .ecdsaSignatureMessageX962SHA256,
            Data("key-preserved".utf8) as CFData, nil) != nil)
    }

    @Test("previous password-backed registrations remain readable")
    func previousRegistration() throws {
        let fixture = try CredentialFixture()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "im.necto.connection.certificate",
            kSecAttrAccount: CredentialFixture.bundleID, kSecMatchSearchList: [fixture.keychain],
        ]
        #expect(SecItemDelete(query as CFDictionary) == errSecSuccess)
        #expect(SecItemAdd([
            kSecClass: kSecClassGenericPassword, kSecAttrService: "im.necto.connection.certificate",
            kSecAttrAccount: CredentialFixture.bundleID, kSecValueData: fixture.identity.certificateDER,
            kSecUseKeychain: fixture.keychain,
        ] as CFDictionary, nil) == errSecSuccess)
        #expect(try fixture.store.identity(bundleID: CredentialFixture.bundleID)?.publicKey == fixture.identity.publicKey)
    }

    @Test("two bundle IDs share one private key and retain independent registrations")
    func sharedKeyAcrossApps() throws {
        let fixture = try CredentialFixture()
        let material = try CredentialFixture.generate(in: fixture.directory)
        let first = CredentialFixture.bundleID + ".first"
        let second = CredentialFixture.bundleID + ".second"
        try fixture.store.install(bundleID: first, privateKeyPEM: material.key, certificateDER: material.certificate)
        try fixture.store.install(bundleID: second, privateKeyPEM: material.key, certificateDER: material.certificate)
        let reopened = NectoKeychainCredentialStore(keychain: fixture.keychain)
        let firstIdentity = try #require(try reopened.identity(bundleID: first))
        let secondIdentity = try #require(try reopened.identity(bundleID: second))
        #expect(firstIdentity.publicKey == secondIdentity.publicKey)
        #expect(CFEqual(firstIdentity.privateKey, secondIdentity.privateKey))
        #expect(try certificateReference(fixture, bundleID: first) == certificateReference(fixture, bundleID: second))
        #expect(SecKeyCopyExternalRepresentation(secondIdentity.privateKey, nil) == nil)
        #expect(try reopened.identity(bundleID: "com.example.unregistered") == nil)
        #expect(throws: NectoSecurityError.keychain(errSecDuplicateItem)) {
            try reopened.install(bundleID: second, privateKeyPEM: material.key, certificateDER: material.certificate)
        }

        #expect(SecItemDelete([
            kSecClass: kSecClassGenericPassword, kSecAttrService: "im.necto.connection.certificate",
            kSecAttrAccount: first, kSecMatchSearchList: [fixture.keychain],
        ] as CFDictionary) == errSecSuccess)
        #expect(try reopened.identity(bundleID: first) == nil)
        #expect(try reopened.identity(bundleID: second)?.publicKey == secondIdentity.publicKey)
    }

    @Test("concurrent installers can register different bundles for the same private key")
    func concurrentSharedKey() async throws {
        let fixture = try CredentialFixture()
        let material = try CredentialFixture.generate(in: fixture.directory)
        let bundles = ["com.example.concurrent.first", "com.example.concurrent.second"]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for bundle in bundles {
                group.addTask {
                    let store = NectoKeychainCredentialStore(keychain: fixture.keychain)
                    try store.install(bundleID: bundle, privateKeyPEM: material.key, certificateDER: material.certificate)
                }
            }
            try await group.waitForAll()
        }
        let first = try #require(try fixture.store.identity(bundleID: bundles[0]))
        let second = try #require(try fixture.store.identity(bundleID: bundles[1]))
        #expect(first.publicKey == second.publicKey)
        #expect(CFEqual(first.privateKey, second.privateKey))
    }

    @Test("a mismatched shared key does not register an app or damage either existing identity")
    func mismatchedSharedKey() throws {
        let fixture = try CredentialFixture()
        let material = try CredentialFixture.generate(in: fixture.directory)
        let first = CredentialFixture.bundleID + ".first"
        let second = CredentialFixture.bundleID + ".second"
        try fixture.store.install(bundleID: first, privateKeyPEM: material.key, certificateDER: material.certificate)
        let initial = try #require(try fixture.store.identity(bundleID: first))
        #expect(throws: NectoSecurityError.invalidIdentity) {
            try fixture.store.install(bundleID: second, privateKeyPEM: material.key,
                certificateDER: fixture.identity.certificateDER)
        }
        #expect(try fixture.store.identity(bundleID: second) == nil)
        #expect(try fixture.store.identity(bundleID: first)?.publicKey == initial.publicKey)
        #expect(try fixture.store.identity(bundleID: CredentialFixture.bundleID)?.publicKey == fixture.identity.publicKey)
        try fixture.store.install(bundleID: second, privateKeyPEM: material.key, certificateDER: material.certificate)
        #expect(try fixture.store.identity(bundleID: second)?.publicKey == initial.publicKey)
    }

    @Test("an extractable existing key is not silently reused")
    func extractableSharedKey() throws {
        let fixture = try CredentialFixture()
        let material = try CredentialFixture.generate(in: fixture.directory)
        var format = SecExternalFormat.formatUnknown
        var type = SecExternalItemType.itemTypePrivateKey
        var items: CFArray?
        try #require(SecItemImport(material.key as CFData, nil, &format, &type, [], nil,
            fixture.keychain, &items) == errSecSuccess)
        let bundle = CredentialFixture.bundleID + ".extractable"
        #expect(throws: NectoSecurityError.invalidIdentity) {
            try fixture.store.install(bundleID: bundle, privateKeyPEM: material.key, certificateDER: material.certificate)
        }
        #expect(try fixture.store.identity(bundleID: bundle) == nil)
        #expect(try fixture.store.identity(bundleID: CredentialFixture.bundleID)?.publicKey == fixture.identity.publicKey)
    }

    @Test("a failed shared-key registration preserves the key, permissions and earlier registration")
    func sharedKeyRollback() throws {
        let fixture = try CredentialFixture()
        let material = try CredentialFixture.generate(in: fixture.directory)
        let first = CredentialFixture.bundleID + ".first"
        let second = CredentialFixture.bundleID + ".second"
        try fixture.store.install(bundleID: first, privateKeyPEM: material.key, certificateDER: material.certificate)
        let original = try #require(try fixture.store.identity(bundleID: first))
        #expect(throws: NectoSecurityError.keychain(errSecAuthFailed)) {
            try fixture.store.install(bundleID: second, privateKeyPEM: material.key,
                certificateDER: material.certificate, trustedApplications: [URL(fileURLWithPath: "/usr/bin/true")])
        }
        #expect(try fixture.store.identity(bundleID: second) == nil)
        let preserved = try #require(try fixture.store.identity(bundleID: first))
        #expect(preserved.publicKey == original.publicKey)
        #expect(SecKeyCreateSignature(preserved.privateKey, .ecdsaSignatureMessageX962SHA256,
            Data("still-authorized".utf8) as CFData, nil) != nil)
        try fixture.store.install(bundleID: second, privateKeyPEM: material.key, certificateDER: material.certificate)
        #expect(try fixture.store.identity(bundleID: second)?.publicKey == original.publicKey)
    }

    @Test("a separately provisioned trusted executable can sign without a Keychain dialog")
    func separateProcess() throws {
        let fixture = try CredentialFixture()
        let source = fixture.directory.appendingPathComponent("signer.swift")
        let executable = fixture.directory.appendingPathComponent("signer")
        // This process has a different code identity from the installer/test runner.
        try Data("""
        import Foundation
        import Security
        SecKeychainSetUserInteractionAllowed(false)
        var keychain: SecKeychain?
        guard SecKeychainOpen(CommandLine.arguments[1], &keychain) == errSecSuccess, let keychain else { exit(1) }
        var registration: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: "im.necto.connection.certificate",
            kSecAttrAccount: CommandLine.arguments[2], kSecMatchSearchList: [keychain], kSecReturnAttributes: true,
        ] as CFDictionary, &registration) == errSecSuccess else { exit(3) }
        guard let record = registration as? [CFString: Any], let reference = record[kSecAttrGeneric] as? Data else { exit(3) }
        var certificate: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass: kSecClassCertificate, kSecMatchItemList: [reference],
            kSecMatchSearchList: [keychain], kSecReturnData: true,
        ] as CFDictionary, &certificate) == errSecSuccess else { exit(3) }
        guard let data = certificate as? Data,
            let parsed = SecCertificateCreateWithData(nil, data as CFData),
            let publicKey = SecCertificateCopyKey(parsed),
            let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
            let label = attributes[kSecAttrApplicationLabel] as? Data else { exit(2) }
        var key: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationLabel: label,
            kSecMatchSearchList: [keychain], kSecReturnRef: true,
        ] as CFDictionary, &key)
        guard status == errSecSuccess, let key else { exit(2) }
        let signature = SecKeyCreateSignature(unsafeDowncast(key, to: SecKey.self),
            .ecdsaSignatureMessageX962SHA256, Data("cross-process".utf8) as CFData, nil)
        if CommandLine.arguments.count > 3 {
            // Public certificate reads must work without granting private-key use.
            guard signature == nil else { exit(5) }
            print("certificate-readable-signing-denied")
            exit(0)
        }
        guard let signature else { exit(4) }
        print((signature as Data).base64EncodedString())
        """.utf8).write(to: source)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", source.path, "-o", executable.path]
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0)
        let material = try CredentialFixture.generate(in: fixture.directory)
        let bundleID = CredentialFixture.bundleID + ".process"
        try fixture.store.install(bundleID: bundleID, privateKeyPEM: material.key,
            certificateDER: material.certificate, trustedApplications: [executable])
        let sharedBundleID = bundleID + ".shared"
        try fixture.store.install(bundleID: sharedBundleID, privateKeyPEM: material.key,
            certificateDER: material.certificate, trustedApplications: [executable])
        for bundle in [bundleID, sharedBundleID] {
            let process = Process()
            process.executableURL = executable
            process.arguments = [fixture.directory.appendingPathComponent("test.keychain-db").path, bundle]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            let signature = try #require(Data(base64Encoded: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            let identity = try #require(try fixture.store.identity(bundleID: bundle))
            let key = try #require(SecKeyCopyPublicKey(identity.privateKey))
            #expect(SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256,
                Data("cross-process".utf8) as CFData, signature as CFData, nil))
        }
        let untrusted = CredentialFixture.bundleID + ".untrusted"
        let untrustedMaterial = try CredentialFixture.generate(in: fixture.directory)
        try fixture.store.install(bundleID: untrusted, privateKeyPEM: untrustedMaterial.key,
            certificateDER: untrustedMaterial.certificate)
        let process = Process()
        process.executableURL = executable
        process.arguments = [fixture.directory.appendingPathComponent("test.keychain-db").path, untrusted, "untrusted"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output, as: UTF8.self).contains("certificate-readable-signing-denied"))
    }

    @Test("both Security export APIs refuse the installed private key")
    func nonExtractable() throws {
        let fixture = try CredentialFixture()
        var error: Unmanaged<CFError>?
        #expect(SecKeyCopyExternalRepresentation(fixture.identity.privateKey, &error) == nil)
        _ = error?.takeRetainedValue()
        var exported: CFData?
        let status = SecItemExport(fixture.identity.privateKey, .formatOpenSSL, .pemArmour, nil, &exported)
        #expect(status != errSecSuccess)
        #expect(exported == nil)
        let publicKey = try #require(SecKeyCopyPublicKey(fixture.identity.privateKey))
        let bytes = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        #expect(try NectoPublicKeyPin(fixture.identity.publicKey).bytes == bytes)
    }

    @Test("each bundle ID selects its own credential, with no default-key fallback")
    func bundleLookup() throws {
        let fixture = try CredentialFixture()
        let other = try CredentialFixture.generate(in: fixture.directory)
        let bundle = CredentialFixture.bundleID + ".second"
        try fixture.store.install(bundleID: bundle, privateKeyPEM: other.key, certificateDER: other.certificate)
        let second = try #require(try fixture.store.identity(bundleID: bundle))
        #expect(second.publicKey != fixture.identity.publicKey)
        #expect(try fixture.store.identity(bundleID: CredentialFixture.bundleID)?.publicKey == fixture.identity.publicKey)
        #expect(try fixture.store.identity(bundleID: "com.example.unknown") == nil)
        #expect(try fixture.store.identity(bundleID: "") == nil)
    }

    @Test("duplicate installation refuses replacement and preserves the existing key")
    func duplicateInstall() throws {
        let fixture = try CredentialFixture()
        let replacement = try CredentialFixture.generate(in: fixture.directory)
        #expect(throws: NectoSecurityError.keychain(errSecDuplicateItem)) {
            try fixture.store.install(bundleID: CredentialFixture.bundleID, privateKeyPEM: replacement.key, certificateDER: replacement.certificate)
        }
        #expect(try fixture.store.identity(bundleID: CredentialFixture.bundleID)?.publicKey == fixture.identity.publicKey)
    }

    @Test("a mismatched certificate leaves no credential and allows a corrected retry")
    func importRollback() throws {
        let fixture = try CredentialFixture()
        let replacement = try CredentialFixture.generate(in: fixture.directory)
        let bundle = CredentialFixture.bundleID + ".retry"
        #expect(throws: NectoSecurityError.invalidIdentity) {
            try fixture.store.install(bundleID: bundle, privateKeyPEM: replacement.key, certificateDER: fixture.identity.certificateDER)
        }
        #expect(try fixture.store.identity(bundleID: bundle) == nil)
        try fixture.store.install(bundleID: bundle, privateKeyPEM: replacement.key, certificateDER: replacement.certificate)
        #expect(try fixture.store.identity(bundleID: bundle) != nil)
    }

    @Test("malformed private keys are not installed")
    func malformedImport() throws {
        let fixture = try CredentialFixture()
        let bundle = CredentialFixture.bundleID + ".invalid"
        #expect(throws: (any Error).self) {
            try fixture.store.install(bundleID: bundle, privateKeyPEM: Data("not a private key".utf8), certificateDER: fixture.identity.certificateDER)
        }
        #expect(try fixture.store.identity(bundleID: bundle) == nil)
    }

    @Test("a public key cannot be used as the host's signing identity")
    func publicKeyOnly() throws {
        let fixture = try CredentialFixture()
        let publicKey = try #require(SecKeyCopyPublicKey(fixture.identity.privateKey))
        #expect(throws: NectoSecurityError.invalidIdentity) {
            _ = try NectoTLSIdentity(certificateDER: fixture.identity.certificateDER, privateKey: publicKey)
        }
    }

    @Test("empty bundle IDs cannot install credentials")
    func emptyBundleID() throws {
        let fixture = try CredentialFixture()
        #expect(throws: NectoSecurityError.invalidIdentity) {
            try fixture.store.install(bundleID: "", privateKeyPEM: Data(), certificateDER: Data())
        }
    }
}
