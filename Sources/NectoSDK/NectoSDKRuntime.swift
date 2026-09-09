//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoTransport
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Holds the listener, the session and the registered plugins behind `NectoSDK`.
///
/// Everything here is about moving messages. Plugins are looked up by contract name
/// and handed the payload untouched, so adding a permission to an app never means
/// changing this file.
final class NectoSDKRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NectoDeviceListener?
    private var task: Task<Void, Never>?
    private var generation: UUID?
    /// Held for the life of the connection. Releasing it would close the socket.
    private var session: NectoMessageSession?
    private var storedStatus: NectoSDK.Status = .stopped
    private var statusContinuations: [UUID: AsyncStream<NectoSDK.Status>.Continuation] = [:]
    private var registered: [any NectoPluginable] = []
    private var registeringIDs: Set<String> = []
    private var requests: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var registrationUpdates: AsyncStream<NectoPluginRegistration>.Continuation?
    private var registrationWriter: Task<Void, Never>?

    var status: NectoSDK.Status {
        get { lock.withLock { storedStatus } }
        set { lock.withLock { setStatusLocked(newValue) } }
    }

    private func setStatusLocked(_ value: NectoSDK.Status) {
        guard storedStatus != value else { return }
        storedStatus = value
        statusContinuations.values.forEach { $0.yield(value) }
    }

    private func setStatus(_ value: NectoSDK.Status, for session: NectoMessageSession) {
        lock.withLock {
            guard self.session === session else { return }
            setStatusLocked(value)
        }
    }

    func statusUpdates() -> AsyncStream<NectoSDK.Status> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.statusContinuations.removeValue(forKey: id)
                }
            }
            lock.withLock {
                statusContinuations[id] = continuation
                continuation.yield(storedStatus)
            }
        }
    }

    var plugins: [any NectoPluginable] { lock.withLock { registered } }

    /// What each plugin answers, read from `register(_:)` when it was added.
    private var handlers: [String: [String: NectoHandler.Registration]] = [:]

    /// Panels read once at registration, held whole. A panel is a few tens of
    /// kilobytes; reading it again for every host that connects would buy nothing.
    private var panels: [String: NectoPanelArchive] = [:]

    private func registration(for invocation: NectoPluginInvocation) -> NectoHandler.Registration? {
        let identity = "\(invocation.name)@\(invocation.version)"
        return lock.withLock { handlers.values.compactMap { $0[identity] }.first }
    }

    @discardableResult
    func register(_ plugin: any NectoPluginable) -> Bool {
        let id = plugin.id
        let reserved = lock.withLock {
            guard !registered.contains(where: { $0.id == id }) else { return false }
            return registeringIDs.insert(id).inserted
        }
        guard reserved else { return false }
        defer { _ = lock.withLock { registeringIDs.remove(id) } }

        let collector = NectoHandler()
        plugin.register(collector)
        guard !collector.hasDuplicateContracts else { return false }
        let registrations = collector.registrations

        // A panel that fails to read is a build problem, and this is a debug tool:
        // say so where the developer is, rather than shipping silence to the Mac.
        var archive: NectoPanelArchive?
        if let panel = plugin.panel {
            archive = try? NectoPanelArchive.read(directory: panel.root)
            assert(archive != nil, "The panel of '\(plugin.id)' could not be read at \(panel.root.path)")
        }

        let accepted = lock.withLock {
            let existing = Set(handlers.values.flatMap { $0.keys })
            guard existing.isDisjoint(with: registrations.keys) else { return false }
            registered.append(plugin)
            handlers[plugin.id] = registrations
            panels[plugin.id] = archive
            enqueueRegistrationLocked(registrationLocked(for: plugin.id))
            return true
        }
        return accepted
    }

    /// Takes a plugin away, from the app and from the host.
    ///
    /// The host is told with the same message as a registration, carrying an empty
    /// catalog: what an app last said about a plugin is the whole truth about it, so
    /// removal needs no message of its own and no new wire type.
    func unregister(id: String) {
        lock.withLock {
            guard let index = registered.firstIndex(where: { $0.id == id }) else { return }
            handlers.removeValue(forKey: id)
            panels.removeValue(forKey: id)
            registered.remove(at: index)
            enqueueRegistrationLocked(registrationLocked(for: id))
        }
    }

    /// How long to wait before rebuilding a listener that ended.
    ///
    /// Long enough not to spin while the app is in the background, short enough that
    /// coming back to the foreground feels immediate.
    private static let retryDelay = Duration.seconds(1)

    func start(port: UInt16) {
        lock.withLock {
            guard task == nil else { return }
            let generation = UUID()
            self.generation = generation
            task = Task { [self] in
                while !Task.isCancelled {
                    await serve(port: port, generation: generation)
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: Self.retryDelay)
                }
            }
        }
    }

    /// Accepts connections until the socket goes away.
    private func serve(port basePort: UInt16, generation: UUID) async {
        var bound: NectoDeviceListener?
        var lastFailure = "No port was available from \(basePort)"
        for offset in 0 ..< Int(NectoDeviceListener.portSpan) {
            guard !Task.isCancelled, let port = UInt16(exactly: Int(basePort) + offset) else { break }
            let candidate = NectoDeviceListener(port: port)
            do {
                try candidate.start()
                bound = candidate
                break
            } catch {
                lastFailure = String(describing: error)
            }
        }
        guard let listener = bound else {
            lock.withLock {
                if self.generation == generation { setStatusLocked(.failed(lastFailure)) }
            }
            return
        }
        let active = lock.withLock {
            guard self.generation == generation, !Task.isCancelled else { return false }
            self.listener = listener
            setStatusLocked(.listening(port: listener.port))
            return true
        }
        guard active else { listener.stop(); return }

        do {

            for try await session in listener.sessions() {
                guard !Task.isCancelled else { session.close(); break }
                await handle(session: session)
            }
        } catch {
            lock.withLock {
                if self.generation == generation { setStatusLocked(.failed(String(describing: error))) }
            }
        }
        listener.stop()
        lock.withLock {
            if self.listener === listener { self.listener = nil }
        }
    }

    func stop() {
        lock.lock()
        let task = task
        let listener = listener
        let session = session
        self.task = nil
        generation = nil
        self.listener = nil
        self.session = nil
        stopRegistrationUpdatesLocked()
        let pending = requests.values.map(\.task)
        requests.removeAll()
        setStatusLocked(.stopped)
        lock.unlock()

        task?.cancel()
        pending.forEach { $0.cancel() }
        session?.close()
        listener?.stop()
    }

    // MARK: Session

    /// Drives one session to completion, independently of how it was obtained.
    ///
    /// The listener path calls this for every connection. Keeping it separate means
    /// the message handling can be exercised over a socket pair, without binding a
    /// port or leaving a listener thread behind.
    func accept(session: NectoMessageSession) async {
        await handle(session: session)
    }

    /// Says hello, tells the host what this app offers, then reads until it goes away.
    private func handle(session: NectoMessageSession) async {
        let previous = lock.withLock { () -> (NectoMessageSession?, [Task<Void, Never>])? in
            guard !Task.isCancelled else { return nil }
            let previous = (self.session, requests.values.map(\.task))
            requests.removeAll()
            stopRegistrationUpdatesLocked()
            self.session = session
            return previous
        }
        guard let previous else { session.close(); return }
        previous.0?.close()
        previous.1.forEach { $0.cancel() }
        defer { disconnect(session) }
        do {
            let hello = await NectoHandshakeHello(
                appBundleID: Self.appBundleID,
                appName: Self.appName,
                appVersion: Self.appVersion,
                deviceName: Self.deviceName(),
                osVersion: Self.osVersion(),
                sdkVersion: NectoSDK.version,
                appIcon: Self.appIcon(),
                simulatorID: ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            )
            let ack = try await session.handshake {
                try await session.send(hello)
                return try await session.receive(NectoHandshakeAck.self)
            }
            guard ack.accepted else {
                setStatus(.failed("Necto refused the connection: \(ack.rejection?.rawValue ?? "unknown")"), for: session)
                session.close()
                return
            }

            guard lock.withLock({ self.session === session }), !Task.isCancelled else {
                session.close()
                return
            }
            setStatus(.connected(appBundleID: hello.appBundleID), for: session)

            startRegistrationUpdates(through: session)
            await readMessages(from: session)
        } catch {
            setStatus(.failed(String(describing: error)), for: session)
            session.close()
        }
    }

    private func readMessages(from session: NectoMessageSession) async {
        while !Task.isCancelled {
            guard let envelope = try? await session.receive(NectoEnvelope.self) else { break }
            route(envelope, session: session)
        }
    }

    private func route(_ envelope: NectoEnvelope, session: NectoMessageSession) {
        switch envelope.type {
        case .pluginInvoke:
            guard let invocation = try? envelope.decode(NectoPluginInvocation.self) else { return }
            lock.withLock {
                guard self.session === session, requests[invocation.requestID] == nil else { return }
                let token = UUID()
                let task = Task { [self] in
                    defer {
                        lock.withLock {
                            if requests[invocation.requestID]?.token == token {
                                requests.removeValue(forKey: invocation.requestID)
                            }
                        }
                    }
                    guard !Task.isCancelled else { return }
                    await perform(invocation, session: session)
                }
                requests[invocation.requestID] = (token, task)
            }

        case .pluginCancel:
            guard let cancel = try? envelope.decode(NectoPluginCancel.self) else { return }
            let task = lock.withLock { () -> Task<Void, Never>? in
                guard self.session === session else { return nil }
                return requests.removeValue(forKey: cancel.requestID)?.task
            }
            task?.cancel()

        // The host never receives these, so an app sending one is a host bug.
        case .pluginRegister, .pluginEvent, .pluginResult:
            break
        }
    }

    // MARK: App contracts

    private func bridgeError(from error: any Error) -> NectoBridgeError {
        (error as? NectoBridgeError)
            ?? NectoBridgeError(code: .providerFailed, message: String(describing: error))
    }

    private func perform(_ invocation: NectoPluginInvocation, session: NectoMessageSession) async {
        let send: @Sendable (NectoPluginResult) async -> Void = { [self] in await self.send($0, through: session) }
        // The panel fetch is answered by the SDK itself: the panel belongs to the
        // registration, not to any operation the plugin declared.
        if invocation.name == NectoPanelArchive.fetchBridge.name,
           invocation.version == NectoPanelArchive.fetchBridge.version {
            let pluginID = invocation.input["pluginID"]?.stringValue ?? ""
            if let archive = lock.withLock({ panels[pluginID] }) {
                await send(NectoPluginResult(requestID: invocation.requestID, output: archive.jsonValue))
            } else {
                await send(NectoPluginResult(
                    requestID: invocation.requestID,
                    error: NectoBridgeError(
                        code: .operationUnavailable,
                        message: "'\(pluginID)' carries no panel"
                    )
                ))
            }
            return
        }

        guard let registration = registration(for: invocation) else {
            await send(NectoPluginResult(
                requestID: invocation.requestID,
                error: NectoBridgeError(
                    code: .operationUnavailable,
                    message: "No plugin registered '\(invocation.name)@\(invocation.version)'"
                )
            ))
            return
        }

        switch registration.body {
        case let .once(body):
            do {
                await send(NectoPluginResult(requestID: invocation.requestID, output: try await body(invocation.input)))
            } catch {
                await send(NectoPluginResult(requestID: invocation.requestID, error: bridgeError(from: error)))
            }

        case let .stream(body):
                let out = NectoHandler.Out { value in
                    await send(NectoPluginResult(
                        requestID: invocation.requestID,
                        output: value,
                        isFinal: false
                    ))
                }

                do {
                    try await body(invocation.input, out)
                    await send(NectoPluginResult(requestID: invocation.requestID))
                } catch is CancellationError {
                    // The caller stopped listening. Nothing to report.
                } catch {
                    await send(NectoPluginResult(
                        requestID: invocation.requestID,
                        error: bridgeError(from: error)
                    ))
                }

        }
    }

    private func startRegistrationUpdates(through session: NectoMessageSession) {
        lock.withLock {
            guard self.session === session, !Task.isCancelled else { return }
            let initial = registered.map { registrationLocked(for: $0.id) }
                .filter { !$0.catalog.bridges.isEmpty || $0.panel != nil }
            let updates = AsyncStream<NectoPluginRegistration>.makeStream(bufferingPolicy: .bufferingOldest(64))
            registrationUpdates = updates.continuation
            registrationWriter = Task { [weak self] in
                do {
                    for registration in initial {
                        try Task.checkCancellation()
                        try await self?.send(registration, through: session)
                    }
                    for await registration in updates.stream {
                        try Task.checkCancellation()
                        try await self?.send(registration, through: session)
                    }
                } catch {
                    self?.disconnect(session)
                }
            }
        }
    }

    private func registrationLocked(for id: String) -> NectoPluginRegistration {
        NectoPluginRegistration(
            pluginID: id,
            catalog: NectoBridgeCatalog(bridges: (handlers[id] ?? [:]).values.map(\.descriptor)),
            panel: panels[id]?.stamp
        )
    }

    private func enqueueRegistrationLocked(_ registration: NectoPluginRegistration) {
        guard let registrationUpdates else { return }
        if case .dropped = registrationUpdates.yield(registration) {
            // Losing a catalog update would leave stale permissions. Reconnect for a full snapshot.
            stopRegistrationUpdatesLocked()
            session?.close()
        }
    }

    private func stopRegistrationUpdatesLocked() {
        registrationUpdates?.finish()
        registrationUpdates = nil
        registrationWriter?.cancel()
        registrationWriter = nil
    }

    private func send(_ registration: NectoPluginRegistration, through session: NectoMessageSession) async throws {
        try await send(
            envelope: NectoEnvelope(type: .pluginRegister, encoding: registration),
            through: session
        )
    }

    // MARK: Sending

    private func send(_ result: NectoPluginResult, through session: NectoMessageSession) async {
        guard !Task.isCancelled, lock.withLock({ self.session === session }) else { return }
        if let envelope = try? NectoEnvelope(type: .pluginResult, encoding: result) {
            try? await send(envelope: envelope, through: session)
            return
        }
        // The output would not encode — NaN in a number, most likely. Dropping the
        // reply here leaves the host waiting out its timeout, so the failure is sent
        // in its place; an error is strings all the way down and always encodes.
        let failure = NectoPluginResult(
            requestID: result.requestID,
            error: NectoBridgeError(code: .providerFailed, message: "The result could not be encoded as JSON")
        )
        guard let envelope = try? NectoEnvelope(type: .pluginResult, encoding: failure) else { return }
        try? await send(envelope: envelope, through: session)
    }

    /// A send failure means the host went away, so the session is dropped and the
    /// listener goes back to waiting rather than piling up unsent messages.
    private func send(envelope: NectoEnvelope, through expected: NectoMessageSession? = nil) async throws {
        let session = expected ?? lock.withLock { self.session }
        guard let session, lock.withLock({ self.session === session }) else { return }

        do {
            try await session.send(envelope)
        } catch {
            disconnect(session)
            throw error
        }
    }

    private func disconnect(_ session: NectoMessageSession) {
        let pending = lock.withLock { () -> [Task<Void, Never>]? in
            guard self.session === session else { return nil }
            self.session = nil
            stopRegistrationUpdatesLocked()
            setStatusLocked(.listening(port: listener?.port ?? 0))
            defer { requests.removeAll() }
            return requests.values.map(\.task)
        }
        session.close()
        guard let pending else { return }

        pending.forEach { $0.cancel() }
    }

    // MARK: App identity

    /// A bundle without an identifier cannot complete the handshake, and a test bundle
    /// is exactly that, so the identity is overridable rather than always read from
    /// `Bundle.main`.
    private static var appBundleID: String {
        if let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty {
            return identifier
        }
        return ProcessInfo.processInfo.environment["NECTO_APP_BUNDLE_ID"] ?? ""
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Unknown"
    }

    /// `UIDevice` is main actor isolated, and the handshake runs on a background task,
    /// so this hops rather than asserting isolation it does not have.
    private static func deviceName() async -> String {
        #if canImport(UIKit)
        await MainActor.run { UIDevice.current.name }
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    /// The largest icon the app bundle declares.
    ///
    /// Read from the bundle rather than asked of the app, so an app never has to hand
    /// Necto an asset it already ships.
    private static func appIcon() async -> Data? {
        #if canImport(UIKit)
        await MainActor.run {
            guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String],
                  let name = files.last,
                  let image = UIImage(named: name)
            else { return nil }
            return image.pngData()
        }
        #else
        nil
        #endif
    }

    private static func osVersion() async -> String {
        #if canImport(UIKit)
        await MainActor.run { UIDevice.current.systemVersion }
        #else
        ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
