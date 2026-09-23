//
// Copyright (c) 2026 Viva Republica, Inc.
//

#if os(macOS)
import Foundation
import Security
import NectoTransport

/// Credentials provisioned by an organization for a particular app bundle ID.
public final class NectoKeychainCredentialStore: @unchecked Sendable {
    // A failed install must not remove a key another install has just reused.
    private static let installLock = NSLock()
    private let keychain: SecKeychain
    private let service = "im.necto.connection.certificate"

    public init(keychain: SecKeychain) { self.keychain = keychain }

    public convenience init() throws {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess, let keychain else { throw NectoSecurityError.keychain(status) }
        self.init(keychain: keychain)
    }

    /// Include the Necto executable in trustedApplications when provisioning from a separate CLI.
    public func install(
        bundleID: String, privateKeyPEM: Data, certificateDER: Data,
        trustedApplications: [URL] = []
    ) throws {
        Self.installLock.lock()
        defer { Self.installLock.unlock() }
        guard !bundleID.isEmpty else { throw NectoSecurityError.invalidIdentity }
        guard try registration(bundleID: bundleID) == nil else { throw NectoSecurityError.keychain(errSecDuplicateItem) }
        let candidate = try importKey(privateKeyPEM)
        _ = try NectoTLSIdentity(certificateDER: certificateDER, privateKey: candidate)
        let applicationLabel = try applicationLabel(of: candidate)
        var applications: [SecTrustedApplication] = []
        for path in [Optional<String>.none] + trustedApplications.map({ Optional($0.path) }) {
            var application: SecTrustedApplication?
            let status = path.map { path in
                path.withCString { SecTrustedApplicationCreateFromPath($0, &application) }
            } ?? SecTrustedApplicationCreateFromPath(nil, &application)
            try check(status)
            guard let application else { throw NectoSecurityError.invalidIdentity }
            applications.append(application)
        }
        var access: SecAccess?
        try check(SecAccessCreate(label(bundleID) as CFString, applications as CFArray, &access))
        guard let access else { throw NectoSecurityError.invalidIdentity }
        let key: SecKey
        let imported: Bool
        do {
            key = try importKey(privateKeyPEM, into: keychain, access: access)
            imported = true
        } catch NectoSecurityError.keychain(errSecDuplicateItem) {
            guard let existing = try privateKey(applicationLabel: applicationLabel),
                  let attributes = SecKeyCopyAttributes(existing) as? [CFString: Any],
                  attributes[kSecAttrIsExtractable] as? Bool == false,
                  attributes[kSecAttrIsSensitive] as? Bool == true
            else { throw NectoSecurityError.invalidIdentity }
            _ = try NectoTLSIdentity(certificateDER: certificateDER, privateKey: existing)
            key = existing
            imported = false
        }
        let keyQuery: [CFString: Any] = [
            kSecClass: kSecClassKey, kSecValueRef: key, kSecMatchSearchList: [keychain],
        ]
        var insertedCertificate: Data?
        do {
            if imported {
                try check(SecItemUpdate(keyQuery as CFDictionary, [kSecAttrLabel: label(bundleID)] as CFDictionary))
            } else {
                try verifySigningAccess(key: key, applications: applications)
            }
            let certificate = try storeCertificate(certificateDER, bundleID: bundleID, access: access)
            if certificate.inserted { insertedCertificate = certificate.reference }
            // Registration metadata is public. Reading a password payload would require a second approval.
            try check(SecItemAdd([
                kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: bundleID, kSecAttrGeneric: certificate.reference,
                kSecValueData: Data(), kSecUseKeychain: keychain,
                kSecAttrAccess: access,
            ] as CFDictionary, nil))
        } catch {
            if let insertedCertificate {
                SecItemDelete([
                    kSecClass: kSecClassCertificate, kSecMatchItemList: [insertedCertificate],
                    kSecMatchSearchList: [keychain],
                ] as CFDictionary)
            }
            if imported { SecItemDelete(keyQuery as CFDictionary) }
            throw error
        }
    }

    public func identity(bundleID: String) throws -> NectoTLSIdentity? {
        guard let certificate = try certificate(bundleID: bundleID) else { return nil }
        guard let parsed = SecCertificateCreateWithData(nil, certificate as CFData),
              let publicKey = SecCertificateCopyKey(parsed),
              let key = try privateKey(applicationLabel: applicationLabel(of: publicKey))
        else { throw NectoSecurityError.invalidIdentity }
        return try NectoTLSIdentity(certificateDER: certificate, privateKey: key)
    }

    private func privateKey(applicationLabel: Data) throws -> SecKey? {
        var key: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationLabel: applicationLabel, kSecMatchSearchList: [keychain],
            kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ] as CFDictionary, &key)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let key, CFGetTypeID(key) == SecKeyGetTypeID() else { throw NectoSecurityError.invalidIdentity }
        return unsafeDowncast(key, to: SecKey.self)
    }

    private func applicationLabel(of key: SecKey) throws -> Data {
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let label = attributes[kSecAttrApplicationLabel] as? Data
        else { throw NectoSecurityError.invalidIdentity }
        return label
    }

    private func registrationQuery(_ bundleID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: bundleID, kSecMatchSearchList: [keychain],
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
    }

    private func certificate(bundleID: String) throws -> Data? {
        guard let attributes = try registration(bundleID: bundleID) else { return nil }
        let query: [CFString: Any]
        if let reference = attributes[kSecAttrGeneric] as? Data, !reference.isEmpty {
            query = [
                kSecClass: kSecClassCertificate, kSecMatchItemList: [reference],
                kSecMatchSearchList: [keychain], kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            ]
        } else {
            // Keep credentials installed by earlier builds readable until they are reprovisioned.
            var legacy = registrationQuery(bundleID)
            legacy[kSecReturnData] = true
            legacy[kSecMatchLimit] = kSecMatchLimitOne
            query = legacy
        }
        var certificate: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &certificate)
        try check(status)
        guard let certificate = certificate as? Data else { throw NectoSecurityError.invalidIdentity }
        return certificate
    }

    private func registration(bundleID: String) throws -> [CFString: Any]? {
        var query = registrationQuery(bundleID)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var attributes: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &attributes)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let attributes = attributes as? [CFString: Any] else { throw NectoSecurityError.invalidIdentity }
        return attributes
    }

    private func storeCertificate(_ data: Data, bundleID: String, access: SecAccess) throws -> (reference: Data, inserted: Bool) {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw NectoSecurityError.invalidIdentity
        }
        var result: CFTypeRef?
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecUseKeychain: keychain,
            kSecAttrLabel: "Necto Certificate: " + bundleID, kSecAttrAccess: access,
            kSecReturnPersistentRef: true,
        ] as CFDictionary, &result)
        if status == errSecDuplicateItem {
            guard let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate),
                  let serial = SecCertificateCopySerialNumberData(certificate, nil)
            else { throw NectoSecurityError.invalidIdentity }
            try check(SecItemCopyMatching([
                kSecClass: kSecClassCertificate, kSecAttrIssuer: issuer, kSecAttrSerialNumber: serial,
                kSecMatchSearchList: [keychain], kSecReturnData: true, kSecReturnPersistentRef: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary, &result))
            guard let existing = result as? [CFString: Any], existing[kSecValueData] as? Data == data,
                  let reference = existing[kSecValuePersistentRef] as? Data
            else { throw NectoSecurityError.invalidIdentity }
            return (reference, false)
        }
        try check(status)
        // The file-based Keychain returns an array for a certificate added by reference.
        let references = result as? [Data]
        guard let reference = (result as? Data) ?? (references?.count == 1 ? references?.first : nil)
        else { throw NectoSecurityError.invalidIdentity }
        return (reference, true)
    }

    private func importKey(_ data: Data, into keychain: SecKeychain? = nil, access: SecAccess? = nil) throws -> SecKey {
        var format = SecExternalFormat.formatUnknown
        var type = SecExternalItemType.itemTypePrivateKey
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        parameters.accessRef = access.map { Unmanaged.passUnretained($0) }
        let usage = [kSecAttrCanSign] as CFArray
        let attributes = (keychain == nil ? [kSecAttrIsSensitive] : [kSecAttrIsPermanent, kSecAttrIsSensitive]) as CFArray
        parameters.keyUsage = Unmanaged.passUnretained(usage)
        // Passing nil would make imported keys extractable by default.
        parameters.keyAttributes = Unmanaged.passUnretained(attributes)
        var items: CFArray?
        try check(withExtendedLifetime((usage, attributes, access)) {
            SecItemImport(data as CFData, nil, &format, &type, [], &parameters, keychain, &items)
        })
        guard let keys = items as? [AnyObject], keys.count == 1,
              let item = keys.first, CFGetTypeID(item) == SecKeyGetTypeID()
        else { throw NectoSecurityError.invalidIdentity }
        return unsafeDowncast(item, to: SecKey.self)
    }

    private func verifySigningAccess(key: SecKey, applications: [SecTrustedApplication]) throws {
        let item = unsafeBitCast(key, to: SecKeychainItem.self)
        var access: SecAccess?
        try check(SecKeychainItemCopyAccess(item, &access))
        guard let access else { throw NectoSecurityError.invalidIdentity }
        let signingACLs = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationSign) as? [SecACL] ?? []
        let requested = try applications.map(trustedApplicationData)
        var allowed: [Data] = []
        for entry in signingACLs {
            var trusted: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            try check(SecACLCopyContents(entry, &trusted, &description, &selector))
            // A nil application list permits every application; preserve the existing policy.
            guard let trusted else { return }
            allowed += try (trusted as? [SecTrustedApplication] ?? []).map(trustedApplicationData)
        }
        // Adding another bundle must not change permissions for apps already sharing this key.
        guard requested.allSatisfy({ allowed.contains($0) }) else {
            throw NectoSecurityError.keychain(errSecAuthFailed)
        }
    }

    private func trustedApplicationData(_ application: SecTrustedApplication) throws -> Data {
        var data: CFData?
        try check(SecTrustedApplicationCopyData(application, &data))
        guard let data else { throw NectoSecurityError.invalidIdentity }
        return data as Data
    }

    private func label(_ bundleID: String) -> String { "Necto Connection: " + bundleID }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NectoSecurityError.keychain(status) }
    }
}
#endif
