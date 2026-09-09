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

    private struct Connection {
        let app: NectoConnectedApp
        let session: NectoMessageSession
    }

    private let port: UInt16
    private let probeInterval: Duration
    private var onEnvelope: (@Sendable (NectoEnvelope, NectoTarget) -> Void)?

    private var connections: [String: Connection] = [:]
    /// Devices usbmuxd has announced, connected or not, so the probe can retry them.
    private var attached: [Int: NectoUSBDevice] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var sessionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[NectoConnectedApp]>.Continuation] = [:]

    public init(
        port: UInt16 = NectoTransportDefaults.devicePort,
        probeInterval: Duration = .seconds(2)
    ) {
        self.port = port
        self.probeInterval = probeInterval
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
        guard tasks.isEmpty else { return }

        notes?(.watchingForDevices)
        tasks.append(Task { await watchDevices() })
        tasks.append(Task { await probe() })
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        for connection in connections.values { connection.session.close() }
        for task in sessionTasks.values { task.cancel() }
        sessionTasks.removeAll()
        connections.removeAll()
        attached.removeAll()
        usbDeviceIDs.removeAll()
        localPorts.removeAll()
        devicePorts.removeAll()
        publish()
    }

    // MARK: Devices

    private func watchDevices() async {
        do {
            for try await event in NectoUSBHub.deviceEvents() {
                guard !Task.isCancelled else { return }
                switch event {
                case let .attached(device) where device.isUSB:
                    attached[device.deviceID] = device
                    await connectToDevice(device)
                case let .detached(deviceID):
                    attached.removeValue(forKey: deviceID)
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
            attached.removeAll()
            removeConnections { $0.usbDeviceID != nil }
        }
    }

    /// Dials every port on the device that does not already carry a session.
    ///
    /// An app that finds the first port taken slides to the next one, so a device
    /// running two builds answers on two ports. Dialing only the first would reach
    /// whichever app started first and leave the other one invisible.
    private func connectToDevice(_ device: NectoUSBDevice) async {
        for candidate in Self.portsToDial(from: port, skipping: connectedPorts(usbDeviceID: device.deviceID)) {
            guard !Task.isCancelled else { return }
            await connectToDevice(device, port: candidate)
        }
    }

    private func connectToDevice(_ device: NectoUSBDevice, port candidate: UInt16) async {
        do {
            let session = try await NectoUSBHub.connect(deviceID: device.deviceID, port: candidate)
            try await accept(
                session: session,
                deviceID: device.serialNumber,
                connection: .usb,
                usbDeviceID: device.deviceID,
                deviceName: await NectoUSBHub.deviceName(deviceID: device.deviceID),
                devicePort: candidate
            )
        } catch {
            // The app is not listening yet. The probe loop keeps trying, because a
            // device usually stays plugged in while its app is started, stopped and
            // started again, and waiting for another attach would mean asking someone
            // to unplug the cable.
        }
    }

    // MARK: Probing

    /// Retries whatever is not connected yet.
    ///
    /// A simulator has nothing to announce it, and a device announces itself once when
    /// the cable goes in, which is rarely the moment its app starts listening. Both
    /// therefore need the same patient retry rather than a single attempt.
    private func probe() async {
        while !Task.isCancelled {
            // Every port in the span, because each simulator app holds one of them.
            for candidate in Self.portsToDial(from: port, skipping: Set(localPorts.values.compactMap { $0 })) {
                guard !Task.isCancelled else { return }
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
            }

            for device in attached.values {
                await connectToDevice(device)
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

    // MARK: Handshake

    @discardableResult
    func accept(
        session: NectoMessageSession,
        deviceID: String,
        connection: NectoConnectedApp.Connection,
        usbDeviceID: Int?,
        deviceName: String? = nil,
        localPort: UInt16? = nil,
        devicePort: UInt16? = nil
    ) async throws -> Task<Void, Never>? {
        let (hello, ack) = try await session.handshake {
            let hello = try await session.receive(NectoHandshakeHello.self)
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

    // MARK: Bookkeeping

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
