//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Security
import NIOPosix
import NectoModel
import NectoTransport
import Testing
@testable import NectoSDK
@testable import NectoMacService
@testable import NectoTransport

final class CredentialFixture: @unchecked Sendable {
    let directory: URL
    let keychain: SecKeychain
    let store: NectoKeychainCredentialStore
    let identity: NectoTLSIdentity
    static let bundleID = "com.example.necto-security-poc"

    init() throws {
        // Unexpected ACL prompts must fail the test instead of asking for a random test password.
        SecKeychainSetUserInteractionAllowed(false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("necto-security-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keychain: SecKeychain?
        let password = UUID().uuidString
        let status = password.withCString {
            SecKeychainCreate(directory.appendingPathComponent("test.keychain-db").path, UInt32(password.utf8.count), $0, false, nil, &keychain)
        }
        guard status == errSecSuccess, let keychain else {
            try? FileManager.default.removeItem(at: directory)
            throw NectoSecurityError.keychain(status)
        }
        let store = NectoKeychainCredentialStore(keychain: keychain)
        do {
            let material = try Self.generate(in: directory)
            try store.install(bundleID: Self.bundleID, privateKeyPEM: material.key, certificateDER: material.certificate)
            identity = try #require(try store.identity(bundleID: Self.bundleID))
        } catch {
            SecKeychainDelete(keychain)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.keychain = keychain
        self.store = store
    }

    deinit {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
    }

    static func generate(in directory: URL) throws -> (key: Data, certificate: Data) {
        let key = directory.appendingPathComponent(UUID().uuidString + ".pem")
        let certificate = directory.appendingPathComponent(UUID().uuidString + ".der")
        defer { try? FileManager.default.removeItem(at: key); try? FileManager.default.removeItem(at: certificate) }
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try openssl(["req", "-new", "-x509", "-key", key.path, "-subj", "/CN=Necto-POC", "-days", "1", "-outform", "DER", "-out", certificate.path])
        return try (Data(contentsOf: key), Data(contentsOf: certificate))
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}

struct SocketPair: Sendable {
    let device: NectoTLSStream
    let host: NectoTLSStream
    func close() { device.close(); host.close() }
}

func withSockets(
    tcp: Bool = false,
    limit: Int = NectoMessageSession.maximumMessageBytes + 4,
    deviceWire: NectoTLSStream.WireTransform? = nil,
    hostWire: NectoTLSStream.WireTransform? = nil,
    _ operation: @Sendable (SocketPair) async throws -> Void
) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let descriptors = try securitySocketDescriptors(tcp: tcp)
        let device = try await NectoTLSStream.adopt(descriptor: descriptors.0, group: group, maximumBufferedBytes: limit, wireTransform: deviceWire)
        let host = try await NectoTLSStream.adopt(descriptor: descriptors.1, group: group, maximumBufferedBytes: limit, wireTransform: hostWire)
        let pair = SocketPair(device: device, host: host)
        do { try await operation(pair) }
        catch { pair.close(); throw error }
        pair.close()
        try await group.shutdownGracefully()
    } catch {
        try await group.shutdownGracefully()
        throw error
    }
}

func securitySocketDescriptors(tcp: Bool) throws -> (Int32, Int32) {
    if !tcp {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        return (descriptors[0], descriptors[1])
    }
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer { Darwin.close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0)
    try #require(listen(listener, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    try #require(named == 0)
    let client = socket(AF_INET, SOCK_STREAM, 0)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    guard connected == 0 else { Darwin.close(client); throw NectoSecurityError.closed }
    let accepted = accept(listener, nil, nil)
    guard accepted >= 0 else { Darwin.close(client); throw NectoSecurityError.closed }
    return (accepted, client)
}

func secureSessions(_ pair: SocketPair, identity: NectoTLSIdentity) async throws -> (NectoMessageSession, NectoMessageSession) {
    async let device = SecurityTestHandshake.device(stream: pair.device, publicKey: identity.publicKey, appBundleID: CredentialFixture.bundleID)
    async let host = SecurityTestHandshake.host(stream: pair.host) { bundleID in
        #expect(bundleID == CredentialFixture.bundleID)
        return identity
    }
    return try await (device, host)
}

final class SecurityLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result { try lock.withLock { try body(&value) } }
}

struct ProbePlugin: NectoPluginable {
    let id = "com.example.poc-probe"
    let calls: SecurityLocked<Int>
    func register(_ necto: NectoHandler) {
        necto.handle("probe.echo") { input in calls.withValue { $0 += 1 }; return input }
    }
}

func acceptSDKHello(_ host: NectoMessageSession) async throws {
    try await host.handshake(timeout: .seconds(3)) {
        _ = try await host.receive(NectoHandshakeHello.self)
        // The SwiftPM runner has no app bundle ID, as in the existing SDK runtime tests.
        try await host.send(NectoHandshakeAck(accepted: true))
        let registration = try await host.receive(NectoEnvelope.self)
        #expect(registration.type == .pluginRegister)
        #expect(try registration.decode(NectoPluginRegistration.self).pluginID == "com.example.poc-probe")
    }
}

func invokeProbe(_ host: NectoMessageSession, id: String = UUID().uuidString) async throws {
    try await host.handshake(timeout: .seconds(3)) {
        try await host.send(NectoEnvelope(type: .pluginInvoke, encoding: NectoPluginInvocation(
            requestID: id, name: "necto.device.probe.echo", version: 1, kind: .once, input: ["id": .string(id)]
        )))
        let envelope = try await host.receive(NectoEnvelope.self)
        #expect(envelope.type == .pluginResult)
        let result = try envelope.decode(NectoPluginResult.self)
        #expect(result.requestID == id)
        #expect(result.output == ["id": .string(id)])
    }
}
