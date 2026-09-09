//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoTransport
import Foundation
import Testing

@testable import NectoSDK

/// Connects to a listener the way usbmuxd does once its tunnel is open: a plain TCP
/// client on the port the app is listening on.
private func connectLocally(to port: UInt16) async throws -> NectoMessageSession {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    return try await NectoMessageSession(stream: NectoSocketStream.connect(to: address))
}

/// Uses port 0 so the kernel assigns a free one and parallel tests cannot collide.
private func startListener() throws -> (NectoDeviceListener, UInt16) {
    let listener = NectoDeviceListener(port: 0)
    try listener.start()
    return (listener, listener.port)
}

@Test func completesTheHandshakeBetweenAppAndHost() async throws {
    let (listener, port) = try startListener()
    defer { listener.stop() }

    // The app side: accept a connection, say hello, wait for the verdict.
    let app = Task {
        let session = try await listener.accept()
        try await session.send(NectoHandshakeHello(
            appBundleID: "com.example.app",
            appName: "Example",
            deviceName: "iPhone",
            sdkVersion: "0.1.0"
        ))
        return try await session.receive(NectoHandshakeAck.self)
    }

    // The host side: read the hello and answer.
    let host = try await connectLocally(to: port)
    defer { host.close() }

    let hello = try await host.receive(NectoHandshakeHello.self)
    #expect(hello.appBundleID == "com.example.app")
    #expect(hello.protocolVersion == NectoProtocol.currentVersion)

    try await host.send(NectoHandshakeAck.evaluate(hello))

    let ack = try await app.value
    #expect(ack.accepted)
}

@Test func refusesAnAppOnAnotherProtocolVersion() async throws {
    let (listener, port) = try startListener()
    defer { listener.stop() }

    let app = Task {
        let session = try await listener.accept()
        try await session.send(NectoHandshakeHello(
            protocolVersion: NectoProtocol.currentVersion + 1,
            appBundleID: "com.example.app",
            appName: "Example",
            deviceName: "iPhone",
            sdkVersion: "0.1.0"
        ))
        return try await session.receive(NectoHandshakeAck.self)
    }

    let host = try await connectLocally(to: port)
    defer { host.close() }

    let hello = try await host.receive(NectoHandshakeHello.self)
    try await host.send(NectoHandshakeAck.evaluate(hello))

    let ack = try await app.value
    #expect(!ack.accepted)
    #expect(ack.rejection == .unsupportedProtocolVersion)
}

@Test func reportsAPortItCannotBind() throws {
    let (listener, port) = try startListener()
    defer { listener.stop() }

    let second = NectoDeviceListener(port: port)
    #expect(throws: NectoDeviceListener.Failure.self) {
        try second.start()
    }
}

@Test func doesNotShadowAnOlderWildcardListener() throws {
    let legacy = socket(AF_INET, SOCK_STREAM, 0)
    try #require(legacy >= 0)
    defer { Darwin.close(legacy) }
    var enabled: Int32 = 1
    setsockopt(legacy, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(legacy, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    try #require(listen(legacy, 4) == 0)
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let read = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(legacy, $0, &size) }
    }
    try #require(read == 0)
    let listener = NectoDeviceListener(port: UInt16(bigEndian: address.sin_port))
    defer { listener.stop() }
    #expect(throws: NectoDeviceListener.Failure.self) { try listener.start() }
}

@Test func restartsTheSamePortAfterClosingAnActiveConnection() async throws {
    let (listener, port) = try startListener()
    defer { listener.stop() }
    let host = try await connectLocally(to: port)
    defer { host.close() }
    let app = try await listener.accept()
    app.close()
    await #expect(throws: NectoSocketStream.Failure.self) {
        _ = try await host.receive(NectoEnvelope.self)
    }
    host.close()
    listener.stop()

    var restarted = false
    for _ in 0..<100 {
        do { try listener.start(); restarted = true; break }
        catch { try await Task.sleep(for: .milliseconds(10)) }
    }
    try #require(restarted)
    #expect(listener.port == port)
    let next = try await connectLocally(to: port)
    defer { next.close() }
    let accepted = try await listener.accept()
    defer { accepted.close() }
    try await accepted.send(NectoHandshakeAck(accepted: true))
    #expect(try await next.receive(NectoHandshakeAck.self).accepted)
}
