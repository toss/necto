//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Security
import NIOCore
import NIOSSL

public enum NectoSecurityError: Error, Equatable {
    case invalidPublicKey
    case invalidIdentity
    case unauthorized
    case unsupportedNegotiation
    case closed
    case concurrentRead
    case bufferLimit
    case keychain(OSStatus)
}

public struct NectoPublicKeyPin: Sendable {
    public let bytes: Data

    public init(_ base64: String) throws {
        guard let data = Data(base64Encoded: base64), data.count == 65,
              SecKeyCreateWithData(data as CFData, [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits: 256,
              ] as CFDictionary, nil) != nil else { throw NectoSecurityError.invalidPublicKey }
        bytes = data
    }

    func matches(_ certificate: NIOSSLCertificate) -> Bool {
        guard let der = try? certificate.toDERBytes(),
              let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData),
              let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return false }
        return data == bytes
    }
}

public struct NectoTLSIdentity: @unchecked Sendable {
    public let certificateDER: Data
    public let privateKey: SecKey
    public let publicKey: String

    public init(certificateDER: Data, privateKey: SecKey) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let certificateKey = SecCertificateCopyKey(certificate),
              let privatePublicKey = SecKeyCopyPublicKey(privateKey),
              let expected = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              let actual = SecKeyCopyExternalRepresentation(privatePublicKey, nil) as Data?,
              expected == actual,
              SecKeyIsAlgorithmSupported(privateKey, .sign, .ecdsaSignatureMessageX962SHA256)
        else { throw NectoSecurityError.invalidIdentity }
        _ = try NectoPublicKeyPin(actual.base64EncodedString())
        self.certificateDER = certificateDER
        self.privateKey = privateKey
        publicKey = actual.base64EncodedString()
    }

    func configuration() throws -> TLSConfiguration {
        let certificate = try NIOSSLCertificate(bytes: Array(certificateDER), format: .der)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(NIOSSLPrivateKey(customPrivateKey: KeychainSigner(key: privateKey, id: publicKey)))
        )
        config.minimumTLSVersion = .tlsv13
        return config
    }
}

private struct KeychainSigner: NIOSSLCustomPrivateKey, Hashable, @unchecked Sendable {
    let key: SecKey
    let id: String
    var signatureAlgorithms: [SignatureAlgorithm] { [.ecdsaSecp256R1Sha256] }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func sign(channel: any Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let bytes = Data(data.readableBytesView)
        // Keychain access can block; never perform it on the network event loop.
        NectoKeychainSigningQueue.shared.submit(keyID: id) {
            guard channel.isActive else {
                promise.fail(NectoSecurityError.closed)
                return
            }
            guard algorithm == .ecdsaSecp256R1Sha256 else {
                promise.fail(NectoSecurityError.invalidIdentity)
                return
            }
            var error: Unmanaged<CFError>?
            if let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, bytes as CFData, &error) {
                promise.succeed(ByteBuffer(bytes: signature as Data))
            } else {
                let failure = error?.takeRetainedValue() as Error? ?? NectoSecurityError.unauthorized
                promise.fail(failure)
            }
        }
        return promise.futureResult
    }

    func decrypt(channel: any Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(NectoSecurityError.invalidIdentity)
    }
}

/// One pending Keychain approval per key, even when several apps or devices share it.
final class NectoKeychainSigningQueue: @unchecked Sendable {
    static let shared = NectoKeychainSigningQueue()
    private let lock = NSLock()
    private var pending: [String: [@Sendable () -> Void]] = [:]

    func submit(keyID: String, operation: @escaping @Sendable () -> Void) {
        let start = lock.withLock {
            let start = pending[keyID] == nil
            pending[keyID, default: []].append(operation)
            return start
        }
        if start { DispatchQueue.global().async { self.drain(keyID) } }
    }

    private func drain(_ keyID: String) {
        while true {
            let operation: (@Sendable () -> Void)? = lock.withLock {
                guard let queue = pending[keyID], !queue.isEmpty else {
                    pending.removeValue(forKey: keyID)
                    return nil
                }
                return pending[keyID]?.removeFirst()
            }
            guard let operation else { return }
            operation()
        }
    }
}
