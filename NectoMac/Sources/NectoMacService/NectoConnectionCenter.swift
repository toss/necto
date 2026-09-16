//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoTransport
import Foundation

/// Finds apps to talk to and keeps their sessions open.
///
/// Two paths reach an app. A device is announced by usbmuxd and reached through a
/// tunnel; a simulator shares the Mac's loopback and has nothing to announce it, so
/// it is probed instead.
///
/// The Mac assigns the device id, because the app cannot know a stable one for
/// itself: a UDID for a device, a fixed value for the simulator.
public actor NectoConnectionCenter {
    public static let simulatorDeviceID = "simulator"

    /// A private Unix socket forwarded by the caller over an authorized ADB transport.
    public struct AndroidEndpoint: Sendable, Hashable {
        public let serial: String
        public let socketPath: String
        public let appBundleID: String

        public init(serial: String, socketPath: String, appBundleID: String) {
            self.serial = serial
            self.socketPath = socketPath
            self.appBundleID = appBundleID
        }

        public static func fromEnvironment(_ environment: [String: String]) -> Self? {
            guard let serial = environment["NECTO_ANDROID_SERIAL"], !serial.isEmpty,
                  let path = environment["NECTO_ANDROID_SOCKET"], path.hasPrefix("/"), !path.contains("\0"),
                  path.utf8.count < 104,
                  let app = environment["NECTO_ANDROID_APP"],
                  app.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$", options: .regularExpression) != nil
            else { return nil }
            return Self(serial: serial, socketPath: path, appBundleID: app)
        }

        func connect() async throws -> NectoMessageSession {
            let parent = URL(filePath: socketPath).deletingLastPathComponent().path
            var directory = stat()
            var socket = stat()
            guard lstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
                  directory.st_uid == getuid(), directory.st_mode & 0o077 == 0,
                  lstat(socketPath, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
                  socket.st_uid == getuid() else { throw POSIXError(.EACCES) }
            return try await NectoMessageSession(stream: NectoSocketStream.connect(unixPath: socketPath))
        }
    }

    private struct Connection {
        let app: NectoConnectedApp
        let session: NectoMessageSession
    }

    private enum Endpoint: Hashable {
        case local(port: UInt16)
        case usb(device: NectoUSBDevice, port: UInt16)
        case android(AndroidEndpoint)

        var usbDeviceID: Int? {
            if case let .usb(device, _) = self { return device.deviceID }
            return nil
        }
    }

    private let port: UInt16
    private let probeInterval: Duration
    private let androidEndpoint: AndroidEndpoint?
    private let appleDiscoveryEnabled: Bool
    private var started = false
    private let deviceEvents: @Sendable () -> AsyncThrowingStream<NectoUSBDeviceEvent, any Error>
    private var onEnvelope: (@Sendable (NectoEnvelope, NectoTarget) -> Void)?

    private var connections: [String: Connection] = [:]
    private var deviceWatcher: Task<Void, Never>?
    private var probes: [Endpoint: Task<Void, Never>] = [:]
    private var sessionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[NectoConnectedApp]>.Continuation] = [:]

    public init(
        port: UInt16 = NectoTransportDefaults.devicePort,
        probeInterval: Duration = .seconds(2),
        androidEndpoint: AndroidEndpoint? = nil,
        appleDiscoveryEnabled: Bool = true
    ) {
        self.init(port: port, probeInterval: probeInterval, deviceEvents: NectoUSBHub.deviceEvents,
                  androidEndpoint: androidEndpoint, appleDiscoveryEnabled: appleDiscoveryEnabled)
    }

    init(
        port: UInt16,
        probeInterval: Duration,
        deviceEvents: @escaping @Sendable () -> AsyncThrowingStream<NectoUSBDeviceEvent, any Error>,
        androidEndpoint: AndroidEndpoint? = nil,
        appleDiscoveryEnabled: Bool = true
    ) {
        self.port = port
        self.probeInterval = probeInterval
        self.deviceEvents = deviceEvents
        self.androidEndpoint = androidEndpoint
        self.appleDiscoveryEnabled = appleDiscoveryEnabled
    }

    public var connectedApps: [NectoConnectedApp] {
        connections.values.map(\.app).sorted { $0.id < $1.id }
    }

    /// Emits the full list whenever it changes, starting with the current one.
    public func updates() -> AsyncStream<[NectoConnectedApp]> {
        AsyncStream { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(connectedApps)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    /// Called for every message an app sends after the handshake.
    public func onMessage(_ handler: @escaping @Sendable (NectoEnvelope, NectoTarget) -> Void) {
        onEnvelope = handler
    }

    /// Sends one message to a connected app. Throws when that app is not connected,
    /// which is how an app contract call reports a target that went away.
    public func send(_ envelope: NectoEnvelope, to target: NectoTarget) async throws {
        let id = NectoConnectedApp.id(for: target)
        guard let session = connections[id]?.session else {
            throw NectoBridgeError(
                code: .targetDisconnected,
                message: "'\(target.appBundleID)' is not connected"
            )
        }
        try await session.send(envelope)
    }

    /// What the transport can tell someone about itself.
    ///
    /// Facts rather than severities: whether "no device attached" is worth telling a
    /// person about depends on what they were trying to do, and this layer does not
    /// know that. The app decides.
    public enum Note: Sendable {
        case watchingForDevices
        case deviceAttached(name: String)
        case deviceDetached
        /// usbmuxd went away. Devices stay unavailable until it is back; the simulator
        /// path is unaffected.
        case usbUnavailable(String)
        case connected(appBundleID: String, over: String)
        case handshakeFailed(reason: String)
    }

    /// Set by whoever wants to hear about it. Nothing here logs on its own — a
    /// transport that writes to a log of its own choosing is a transport that has to be
    /// silenced later.
    private var notes: (@Sendable (Note) -> Void)?

    public func setNotes(_ notes: @escaping @Sendable (Note) -> Void) {
        self.notes = notes
    }

    public func start() {
        guard !started else { return }
        started = true

        if appleDiscoveryEnabled {
            notes?(.watchingForDevices)
            deviceWatcher = Task { await watchDevices() }
            for candidate in Self.portsToDial(from: port, skipping: []) {
                startProbe(.local(port: candidate))
            }
        }
        if let androidEndpoint { startProbe(.android(androidEndpoint)) }
    }

    public func stop() {
        started = false
        deviceWatcher?.cancel()
        deviceWatcher = nil
        for probe in probes.values { probe.cancel() }
        probes.removeAll()
        for connection in connections.values { connection.session.close() }
        for task in sessionTasks.values { task.cancel() }
        sessionTasks.removeAll()
        connections.removeAll()
        usbDeviceIDs.removeAll()
        localPorts.removeAll()
        devicePorts.removeAll()
        publish()
    }

    private func watchDevices() async {
        do {
            for try await event in deviceEvents() {
                guard !Task.isCancelled else { return }
                switch event {
                case let .attached(device) where device.isUSB:
                    for candidate in Self.portsToDial(from: port, skipping: []) {
                        startProbe(.usb(device: device, port: candidate))
                    }
                case let .detached(deviceID):
                    cancelUSBProbes { $0 == deviceID }
                    removeConnections { $0.usbDeviceID == deviceID }
                case .attached:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            // usbmuxd went away. Devices stay unavailable until it comes back, and the
            // simulator path keeps working.
            notes?(.usbUnavailable(String(describing: error)))
            cancelUSBProbes { _ in true }
            removeConnections { $0.usbDeviceID != nil }
        }
    }

    private func cancelUSBProbes(where matches: (Int) -> Bool) {
        for endpoint in probes.keys.filter({ $0.usbDeviceID.map(matches) == true }) {
            probes.removeValue(forKey: endpoint)?.cancel()
        }
    }

    private func connectToDevice(_ device: NectoUSBDevice, port candidate: UInt16) async {
        do {
            let session = try await NectoUSBHub.connect(deviceID: device.deviceID, port: candidate)
            _ = try await withTaskCancellationHandler {
                try await accept(
                    session: session,
                    deviceID: device.serialNumber,
                    connection: .usb,
                    usbDeviceID: device.deviceID,
                    deviceName: await NectoUSBHub.deviceName(deviceID: device.deviceID),
                    devicePort: candidate
                )
            } onCancel: {
                // The SDK socket is already open while lockdownd supplies the name.
                session.close()
            }
        } catch {
            // The app is not listening yet. The probe loop keeps trying, because a
            // device usually stays plugged in while its app is started, stopped and
            // started again, and waiting for another attach would mean asking someone
            // to unplug the cable.
        }
    }

    private func startProbe(_ endpoint: Endpoint) {
        guard probes[endpoint] == nil else { return }
        probes[endpoint] = Task { await probe(endpoint) }
    }

    /// Each endpoint owns its retry interval; a silent app cannot stall another app
    /// or prevent the USB watcher from handling a detach.
    private func probe(_ endpoint: Endpoint) async {
        while !Task.isCancelled {
            switch endpoint {
            case let .local(candidate) where !localPorts.values.contains(candidate):
                do {
                    let session = try await NectoLocalConnector.connect(port: candidate)
                    try await accept(
                        session: session,
                        deviceID: Self.simulatorDeviceID,
                        connection: .simulator,
                        usbDeviceID: nil,
                        localPort: candidate
                    )
                } catch {
                    // Nothing listening there. Try again after the interval.
                }
            case let .usb(device, candidate) where !connectedPorts(usbDeviceID: device.deviceID).contains(candidate):
                await connectToDevice(device, port: candidate)
            case let .android(endpoint) where !connections.values.contains(where: { $0.app.target.deviceID == "android:\(endpoint.serial)" }):
                do {
                    let session = try await endpoint.connect()
                    try await withTaskCancellationHandler {
                        try await accept(
                            session: session,
                            deviceID: "android:\(endpoint.serial)",
                            connection: endpoint.serial.hasPrefix("emulator-") ? .androidEmulator : .androidDevice,
                            usbDeviceID: nil,
                            expectedAppBundleID: endpoint.appBundleID
                        )
                    } onCancel: {
                        session.close()
                    }
                } catch {
                    // ADB forwarding survives an app restart; retry the same endpoint.
                }
            default:
                break
            }

            try? await Task.sleep(for: probeInterval)
        }
    }

    /// The ports worth dialing: the whole span, minus the ones already answered.
    static func portsToDial(from base: UInt16, skipping taken: Set<UInt16>) -> [UInt16] {
        (0..<Int(NectoTransportDefaults.portSpan))
            .compactMap { UInt16(exactly: Int(base) + $0) }
            .filter { !taken.contains($0) }
    }

    /// Which ports on one device already carry a session.
    private func connectedPorts(usbDeviceID: Int) -> Set<UInt16> {
        Set(usbDeviceIDs.compactMap { id, attachedTo in
            attachedTo == usbDeviceID ? devicePorts[id] : nil
        })
    }

    @discardableResult
    func accept(
        session: NectoMessageSession,
        deviceID: String,
        connection: NectoConnectedApp.Connection,
        usbDeviceID: Int?,
        deviceName: String? = nil,
        localPort: UInt16? = nil,
        devicePort: UInt16? = nil,
        expectedAppBundleID: String? = nil
    ) async throws -> Task<Void, Never>? {
        let (hello, ack) = try await session.handshake {
            let hello = try await session.receive(NectoHandshakeHello.self)
            if let expectedAppBundleID, hello.appBundleID != expectedAppBundleID {
                session.close()
                throw POSIXError(.EACCES)
            }
            let ack = NectoHandshakeAck.evaluate(hello)
            try await session.send(ack)
            return (hello, ack)
        }
        guard !Task.isCancelled else { session.close(); throw CancellationError() }

        guard ack.accepted else {
            // The one failure a person can act on: their app and this Necto do not speak
            // the same protocol, so one of the two needs updating.
            notes?(.handshakeFailed(reason: "\(hello.appBundleID) speaks protocol \(hello.protocolVersion); this Necto speaks \(NectoProtocol.currentVersion)"))
            session.close()
            return nil
        }

        // A simulator names itself: they all share the Mac's loopback, and without the
        // UDID every one of them would be the same device.
        let resolvedDeviceID = connection == .simulator ? (hello.simulatorID ?? deviceID) : deviceID

        let app = NectoConnectedApp(
            target: NectoTarget(deviceID: resolvedDeviceID, appBundleID: hello.appBundleID),
            // What lockdownd reports when it answered, since the app can only see the
            // model name.
            deviceName: deviceName ?? hello.deviceName,
            osVersion: hello.osVersion,
            appName: hello.appName,
            appVersion: hello.appVersion,
            sdkVersion: hello.sdkVersion,
            connection: connection,
            appIcon: hello.appIcon
        )

        connections[app.id]?.session.close()
        connections[app.id] = Connection(app: app, session: session)
        notes?(.connected(appBundleID: app.target.appBundleID, over: connection == .usb ? "USB" : "loopback"))
        usbDeviceIDs[app.id] = usbDeviceID
        localPorts[app.id] = localPort
        devicePorts[app.id] = devicePort
        publish()

        let reader = Task { await readMessages(from: app, session: session) }
        sessionTasks[ObjectIdentifier(session)] = reader
        return reader
    }

    /// Reads until the app goes away. A read failure is how a disconnect surfaces on
    /// the simulator path, which has no attach and detach events.
    private func readMessages(from app: NectoConnectedApp, session: NectoMessageSession) async {
        let handler = onEnvelope
        let target = app.target

        while !Task.isCancelled {
            guard let envelope = try? await session.receive(NectoEnvelope.self) else { break }
            guard connections[app.id]?.session === session else { break }
            handler?(envelope, target)
        }
        sessionTasks.removeValue(forKey: ObjectIdentifier(session))
        guard connections[app.id]?.session === session else { return }
        removeConnections { $0.id == app.id }
    }

    private var usbDeviceIDs: [String: Int?] = [:]
    /// Which loopback port each simulator connection came in on, so the probe skips
    /// ports that already carry a session.
    private var localPorts: [String: UInt16?] = [:]
    /// The same, for a device: an app that slid past a taken port is only reachable
    /// on the one it settled on.
    private var devicePorts: [String: UInt16] = [:]

    private struct ConnectionKey {
        let id: String
        let usbDeviceID: Int?
    }

    private func removeConnections(where matches: (ConnectionKey) -> Bool) {
        let removable = connections.keys.filter { id in
            matches(ConnectionKey(id: id, usbDeviceID: usbDeviceIDs[id] ?? nil))
        }
        guard !removable.isEmpty else { return }

        for id in removable {
            connections.removeValue(forKey: id)?.session.close()
            usbDeviceIDs.removeValue(forKey: id)
            localPorts.removeValue(forKey: id)
            devicePorts.removeValue(forKey: id)
        }
        publish()
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func publish() {
        let snapshot = connectedApps
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }
}
