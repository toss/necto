//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoCLIService
import NectoMacService
import NectoModel
import Foundation
import Observation

/// Owns the app-wide plugin runtime, installation state and connected apps.
/// Feature logic belongs in the registry and its providers, not here.
@MainActor
@Observable
final class NectoAppModel {
    static let nectoVersion = NectoSemanticVersion(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    ) ?? NectoSemanticVersion(major: 0, minor: 0, patch: 0)

    private(set) var plugins: [NectoInstalledPlugin] = [] {
        didSet { refreshBackgroundPanels() }
    }
    /// Why a plugin on disk is not in `plugins`, keyed by folder name. Shown in
    /// Settings rather than only printed, because a plugin that silently fails to
    /// appear is the hardest kind to debug.
    private(set) var pluginFailures: [String: String] = [:]
    private(set) var pluginsAwaitingApproval: [NectoInstalledPlugin] = []
    private(set) var disabledIDs = NectoPluginLibrary.disabledIDs {
        didSet { refreshBackgroundPanels() }
    }
    /// Mirrors `NectoPluginLibrary.deviceOrder` so a drop re-renders the list at
    /// once: UserDefaults is where the order lives, but it is not observable.
    private(set) var deviceOrder = NectoPluginLibrary.deviceOrder

    typealias PendingInstall = InstallCoordinator.PendingInstall
    typealias PendingChoice = InstallCoordinator.PendingChoice
    typealias Prompt = InstallCoordinator.Prompt
    @ObservationIgnored private lazy var installer = InstallCoordinator(
        shellAccess: shellAccess,
        reload: { [weak self] in
            guard let self else { return [] }
            await self.reloadPluginCatalog()
            return self.plugins
        },
        present: { [weak self] in
            guard let self else { throw NectoBridgeError(code: .operationUnavailable, message: "Necto is closing.") }
            try self.presentInstaller()
        },
        delete: { [weak self] id in
            guard let self else { throw NectoBridgeError(code: .operationUnavailable, message: "Necto is closing.") }
            return try await self.removeInstalledPlugin(id: id)
        },
        logFailure: { [weak self] title, detail in
            Task { await self?.log(.failure, .plugin, title, detail: detail) }
        }
    )
    var prompt: Prompt? { installer.prompt }
    var pendingInstall: PendingInstall? { installer.pendingInstall }
    var pendingChoice: PendingChoice? { installer.pendingChoice }
    var installFailure: String? { installer.installFailure }
    var isAddingLink: Bool { installer.isAddingLink }
    var isReadingRelease: Bool { installer.isReadingRelease }
    var isFetching: Bool { installer.isFetching }
    var isInstalling: Bool { installer.isBusy }
    var fetchingAsset: String? { installer.fetchingAsset }
    var queuedAssets: Set<String> { installer.queuedAssets }

    private(set) var connectedApps: [NectoConnectedApp] = []

    let backgroundPanels = NectoBackgroundPanels()
    private(set) var presentationWindowID: UUID?
    @ObservationIgnored private var windows: [UUID: WeakWindow] = [:]

    private struct WeakWindow { weak var value: NectoWindowState? }

    func registerWindow(_ state: NectoWindowState) { windows[state.id] = WeakWindow(value: state) }

    func unregisterWindow(_ state: NectoWindowState) {
        windows.removeValue(forKey: state.id)
        backgroundPanels.release(windowID: state.id)
        if presentationWindowID == state.id {
            presentationWindowID = nil
            routePendingPrompt()
        }
    }

    private func presentInstaller() throws {
        guard let state = presentationWindow() else {
            throw NectoBridgeError(code: .operationUnavailable, message: "Open a Necto window before installing a plugin.")
        }
        presentationWindowID = state.id
        state.isShowingSettings = true
        state.window?.deminiaturize(nil)
        state.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func presentationWindow() -> NectoWindowState? {
        let available = windows.values.compactMap(\.value).filter { $0.window != nil }
        if let current = available.first(where: { $0.id == presentationWindowID }) { return current }
        return available.first(where: { $0.window?.isKeyWindow == true })
            ?? available.first(where: { $0.window?.isMainWindow == true })
            ?? available.first
    }

    func routePendingPrompt() {
        guard prompt != nil || shellAccess.pendingApproval != nil else {
            presentationWindowID = nil
            return
        }
        guard let state = presentationWindow() else { return }
        presentationWindowID = state.id
        if prompt != nil { state.isShowingSettings = true }
    }

    private func refreshBackgroundPanels() {
        backgroundPanels.synchronize(plugins: enabledPlugins.filter(\.runsInBackground), registry: registry)
    }

    // MARK: Device plugins

    /// One plugin a connected app carried in, with the app it belongs to.
    struct DiscoveredPlugin: Identifiable, Sendable {
        let plugin: NectoInstalledPlugin
        let target: NectoTarget
        var id: String { plugin.id }
    }

    private let deviceStore = NectoDevicePluginStore()
    /// Registered and in the sidebar while their app is selected. No approval stands
    /// between an app and its own plugins: whoever added the package to the app
    /// already said yes, in code, where saying yes means something. The sheet is for
    /// desktop installs, where a third party's work enters.
    private(set) var devicePlugins: [DiscoveredPlugin] = []

    private static let targetHandles = NectoTargetHandles()

    let registry = NectoPluginRegistry(targetHandles: NectoAppModel.targetHandles)

    private let connections = NectoConnectionCenter()
    private let storage = NectoPluginStorage()
    private let events = NectoPluginEventRouter()
    let diagnostics = NectoDiagnosticsLog()
    let updater = NectoUpdater(current: NectoAppModel.nectoVersion)
    let shellAccess: NectoShellAccessController
    /// Mirrors `diagnostics.unreadIssueCount()` so SwiftUI can watch it. The log is an
    /// actor and a badge cannot await.
    private(set) var unreadIssueCount = 0
    private let appBridge: NectoDeviceBridgeClient
    private var connectionTask: Task<Void, Never>?

    init() {
        shellAccess = NectoShellAccessController(snapshot: NectoPluginLibrary.shellPolicy) {
            NectoPluginLibrary.shellPolicy = $0
        }
        appBridge = NectoDeviceBridgeClient(messenger: Messenger(connections: connections))
    }

    /// What the Device Plugins section lists, in the order the user arranged.
    func activeDevicePlugins(for target: NectoTarget?) -> [NectoInstalledPlugin] {
        guard let target else { return [] }
        return NectoPluginLibrary.sorted(
            devicePlugins
                .filter { $0.target == target && !disabledIDs.contains($0.id) }
                .map(\.plugin),
            by: deviceOrder
        )
    }

    /// Sunken to the bottom of the section, in gray. Alphabetical on purpose: what
    /// needs no arranging gets no arranging.
    func disabledDevicePlugins(for target: NectoTarget?) -> [NectoInstalledPlugin] {
        guard let target else { return [] }
        return devicePlugins
            .filter { $0.target == target && disabledIDs.contains($0.id) }
            .map(\.plugin)
            .sorted { $0.manifest.name < $1.manifest.name }
    }

    func moveDevicePlugins(from source: IndexSet, to destination: Int, target: NectoTarget?) {
        var arranged = activeDevicePlugins(for: target)
        arranged.move(fromOffsets: source, toOffset: destination)

        // The moved block leads; ids it does not mention — disabled ones, other
        // devices' plugins — keep their old standing behind it rather than being
        // forgotten by an arrangement that never showed them.
        let moved = arranged.map(\.id)
        let kept = NectoPluginLibrary.deviceOrder.filter { !moved.contains($0) }
        NectoPluginLibrary.deviceOrder = moved + kept
        deviceOrder = NectoPluginLibrary.deviceOrder
    }

    /// What the sidebar lists, in the order the user arranged. A disabled plugin stays
    /// installed and keeps its folder, it just stops being somewhere to navigate to.
    var enabledPlugins: [NectoInstalledPlugin] {
        plugins.filter { !disabledIDs.contains($0.id) }
    }

    /// Takes the move `List` already worked out, once, when the row is dropped.
    func movePlugins(from source: IndexSet, to destination: Int) {
        var enabled = enabledPlugins
        enabled.move(fromOffsets: source, toOffset: destination)

        // Disabled plugins keep their places, so turning one back on does not move it.
        plugins = enabled + plugins.filter { disabledIDs.contains($0.id) }

        // The whole list is written, not just the pair that moved: an order held as
        // gaps between neighbours drifts as plugins come and go.
        NectoPluginLibrary.order = plugins.map(\.id)
    }

    /// Records a line and republishes what the badge reads.
    func log(
        _ severity: NectoDiagnosticsLog.Severity,
        _ source: NectoDiagnosticsLog.Source,
        _ message: String,
        detail: String? = nil
    ) async {
        await diagnostics.append(severity, source, message, detail: detail)
        unreadIssueCount = await diagnostics.unreadIssueCount()
    }

    func acknowledgeIssues() async {
        await diagnostics.acknowledge()
        unreadIssueCount = await diagnostics.unreadIssueCount()
    }

    func setPlugin(_ id: String, enabled: Bool) {
        NectoPluginLibrary.setEnabled(id, enabled)
        disabledIDs = NectoPluginLibrary.disabledIDs

    }

    // MARK: Installing

    func installPluginFromCLI(source: NectoPluginInstallSource) async throws -> NectoJSONValue {
        try await installer.installPluginFromCLI(source: source)
    }
    func beginInstallFromFile(updating plugin: NectoInstalledPlugin? = nil) { installer.beginInstallFromFile(updating: plugin) }
    func review(_ plugin: NectoInstalledPlugin) { installer.review(plugin) }
    func beginAddingLink() { installer.beginAddingLink() }
    func cancelAddingLink() { installer.cancelAddingLink() }
    func dismissPrompt() { installer.dismissPrompt() }
    func beginInstallFromLink(_ text: String) { installer.beginInstallFromLink(text) }
    func cancelChoice() { installer.cancelChoice() }
    func install(_ offer: NectoReleaseSource.Offer) { installer.install(offer) }
    func cancelInstall() { installer.cancelInstall() }
    func confirmInstall() { installer.confirmInstall() }

    // MARK: Following a source

    /// A newer release of a plugin that was installed from one.
    struct PluginUpdate {
        let offer: NectoReleaseSource.Offer
        let repository: NectoReleaseSource.Repository
        let tag: String
        let version: NectoSemanticVersion
        let name: String
    }

    private(set) var pluginUpdates: [String: PluginUpdate] = [:]
    private(set) var isCheckingUpdates = false

    /// Opening the Plugins page checks, and people open it often. Anonymous GitHub
    /// allows sixty requests an hour, and every repository followed costs one request
    /// plus one for each plugin installed from it, so an unthrottled check on every
    /// visit would spend the hour and then report a rate limit as if something were
    /// wrong. Asking explicitly ignores this.
    private var lastUpdateCheck: Date?
    private static let updateCheckInterval: TimeInterval = 15 * 60

    /// Looks for newer releases of everything installed from a repository.
    ///
    /// Only desktop plugins are followed. A device plugin's panel is half of a pair
    /// with the handlers in the app that answers it, and moving one without the other
    /// is how a panel starts calling bridges that are no longer there — so those
    /// arrive with their app or not at all.
    ///
    /// A version is compared, never a tag. One tag covers every plugin in a
    /// repository that publishes several, so the tag says nothing about any one of
    /// them; the manifest published beside an archive does. A release without those
    /// manifests cannot be compared without downloading all of it, and downloading
    /// something to find out whether it was wanted is not a check.
    func checkPluginUpdates(quietly: Bool = true) async {
        guard !isCheckingUpdates else { return }
        if quietly, let last = lastUpdateCheck, Date().timeIntervalSince(last) < Self.updateCheckInterval {
            return
        }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        var found: [String: PluginUpdate] = [:]
        var releases: [String: NectoReleaseSource.Release] = [:]

        for plugin in plugins {
            guard plugin.source == .installed,
                  let origin = plugin.installation?.origin,
                  let installed = NectoSemanticVersion(plugin.manifest.version) else { continue }

            let repository = NectoReleaseSource.Repository(
                host: origin.host,
                owner: origin.owner,
                name: origin.repository
            )

            let release: NectoReleaseSource.Release
            if let known = releases[repository.label] {
                release = known
            } else {
                do {
                    // By identity, not by ==: an Origin carries the release it came
                    // from, so two plugins installed out of the same repository at
                    // different times compare unequal, and asking about one of them
                    // would leave the other unasked about for good.
                    release = try await NectoReleaseSource.release(
                        of: repository,
                        describing: Set(
                            plugins
                                .filter { $0.installation?.origin?.identity == origin.identity }
                                .map(\.id)
                        )
                    )
                    releases[repository.label] = release
                } catch {
                    if !quietly { installer.report(error) }
                    continue
                }
            }

            guard let offer = release.offers.first(where: { $0.manifest?.id == plugin.id }),
                  let manifest = offer.manifest,
                  let published = NectoSemanticVersion(manifest.version),
                  published > installed else { continue }

            found[plugin.id] = PluginUpdate(
                offer: offer,
                repository: repository,
                tag: release.tag,
                version: published,
                name: plugin.manifest.name
            )
        }

        pluginUpdates = found
        lastUpdateCheck = Date()
    }

    /// Fetches the newer release and asks, the same way a first install asks. An
    /// update is not a smaller decision than an install: it can bind to something the
    /// last version did not.
    func installUpdate(for pluginID: String) {
        guard let update = pluginUpdates[pluginID],
              installer.enqueueUpdate(offer: update.offer, repository: update.repository,
                                      tag: update.tag, expecting: pluginID) else { return }
        pluginUpdates.removeValue(forKey: pluginID)
    }

    // MARK: Removing

    func deletePluginFromCLI(id: String) async throws -> NectoJSONValue {
        try await installer.deletePlugin(id: id)
    }

    func remove(_ plugin: NectoInstalledPlugin) {
        Task {
            do { _ = try await installer.deletePlugin(id: plugin.id) }
            catch {
                pluginFailures[plugin.manifest.name] = NectoL10n.format("Could not remove: %@", error.localizedDescription)
                await log(.failure, .plugin, "Could not remove \(plugin.manifest.name)", detail: error.localizedDescription)
            }
        }
    }

    private func removeInstalledPlugin(id: String) async throws -> NectoJSONValue {
        guard let plugin = (plugins + pluginsAwaitingApproval).first(where: { $0.id == id && $0.source == .installed }) else {
            throw NectoBridgeError(code: .operationNotFound, message: "No installed desktop plugin has that ID. Device plugins are managed by their app.")
        }
        try NectoPluginLibrary.remove(plugin)

        // The approval goes with it. Installing the same plugin again is a new
        // decision, not a resumption of an old one.
        var grants = NectoPluginLibrary.grants
        let principal = plugin.principal
        if let principal { grants.revoke(principal) }
        NectoPluginLibrary.grants = grants
        var records = NectoPluginLibrary.installations
        records.removeValue(forKey: plugin.id)
        NectoPluginLibrary.installations = records
        if let principal { shellAccess.cancelRequests(for: principal) }
        await registry.uninstall(pluginID: plugin.id)
        if let principal { await shellAccess.forget(principal) }

        plugins.removeAll { $0.id == plugin.id }
        pluginsAwaitingApproval.removeAll { $0.id == plugin.id }
        disabledIDs = NectoPluginLibrary.disabledIDs
        pluginUpdates.removeValue(forKey: id)
        return ["deleted": true, "pluginID": .string(id)]
    }

    struct ConnectedApp: Identifiable {
        let bundleID: String
        let name: String
        /// The same app on each device it was found on, newest listing first.
        let devices: [NectoConnectedApp]

        var id: String { bundleID }
    }

    /// Connected apps, each with the devices running it.
    ///
    /// The app leads rather than the device, because a plugin is written for an app
    /// and the same app is commonly running on several devices at once. The device is
    /// then the choice, not the heading.
    var apps: [ConnectedApp] {
        var order: [String] = []
        var grouped: [String: [NectoConnectedApp]] = [:]

        for app in connectedApps {
            let key = app.appBundleID
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(app)
        }

        return order.compactMap { key in
            guard let devices = grouped[key], let first = devices.first else { return nil }
            return ConnectedApp(bundleID: key, name: first.appName, devices: devices)
        }
    }

    /// Held so it lives as long as the app; the CLI connects whenever it likes.
    private var controlServer: NectoControlServer?

    private func startControlServer() async {
        let server = NectoControlServer(handler: NectoControlBridge(
            registry: registry,
            connectedApps: { [weak self] in
                await MainActor.run { self?.connectedApps ?? [] }
            },
            install: { [weak self] source in
                guard let self else {
                    throw NectoBridgeError(code: .operationUnavailable, message: "Necto is closing.")
                }
                return try await self.installPluginFromCLI(source: source)
            },
            delete: { [weak self] id in
                guard let self else { throw NectoBridgeError(code: .operationUnavailable, message: "Necto is closing.") }
                return try await self.deletePluginFromCLI(id: id)
            }
        ))
        do {
            try server.start()
            controlServer = server
            await log(.info, .connection, "Listening for necto-cli")
        } catch {
            await log(.warning, .connection, "The control socket could not open", detail: String(describing: error))
        }
    }

    @ObservationIgnored private var startupTask: Task<Void, Never>?

    func load() async {
        if startupTask == nil { startupTask = Task { await start() } }
        await startupTask?.value
    }

    private func start() async {
        await diagnostics.append(.info, .connection, "Necto \(Self.nectoVersion) started")
        await registerHostProviders()
        await registerCLIPlugin()
        await installer.reloadPlugins()
        await startControlServer()
        Task { await updater.check(quietly: true) }
        startWatchingConnections()
    }

    private func startWatchingConnections() {
        guard connectionTask == nil else { return }

        // The transport reports facts; which of them is worth telling someone about is
        // decided here, where what the person was trying to do is known.
        Task {
            await connections.setNotes { [weak self] note in
                Task { @MainActor in
                    guard let self else { return }
                    switch note {
                    case .watchingForDevices:
                        await self.log(.info, .connection, "Listening for apps")
                    case let .usbUnavailable(reason):
                        await self.log(
                            .failure,
                            .connection,
                            "Cannot see USB devices",
                            detail: reason + " — a simulator still connects over loopback."
                        )
                    case let .connected(appBundleID, over):
                        await self.log(.info, .target, "\(appBundleID) connected over \(over)")
                    case let .handshakeFailed(reason):
                        await self.log(.failure, .connection, "An app was turned away", detail: reason)
                    case .deviceAttached, .deviceDetached:
                        break
                    }
                }
            }
        }

        connectionTask = Task { [connections, events, appBridge, registry] in
            await connections.onMessage { [weak self] envelope, target in
                Task {
                    await Self.route(envelope, from: target, events: events, appBridge: appBridge, registry: registry)

                    // The panel half of a registration involves the plugin list, the
                    // cache and possibly a question on screen, all of which live on the
                    // model rather than in the message plumbing.
                    if envelope.type == .pluginRegister,
                       let registration = try? envelope.decode(NectoPluginRegistration.self) {
                        await self?.receivedRegistration(registration, from: target)
                    }
                }
            }
            await connections.start()

            var known: Set<NectoTarget> = []
            for await apps in await connections.updates() {
                connectedApps = apps

                // An app that went away takes its contracts and its parked calls with it.
                let current = Set(apps.map(\.target))
                for target in known.subtracting(current) {
                    await registry.unregisterDeviceProviders(for: target)
                    await appBridge.targetDisconnected(target)
                    await dropDevicePlugins(for: target)
                    // Ordinary: an app is stopped and started all day. A warning, not a
                    // failure, or the badge would light up for nothing.
                    await log(.warning, .target, "\(target.appBundleID) disconnected")
                }
                for target in current.subtracting(known) {
                    await log(.info, .target, "\(target.appBundleID) connected")
                }
                known = current


            }
        }
    }

    /// Plugin messages only. The transport has no idea what any of them mean, and the
    /// only thing that changes when a new SDK plugin appears is a channel handler.
    private static func route(
        _ envelope: NectoEnvelope,
        from target: NectoTarget,
        events: NectoPluginEventRouter,
        appBridge: NectoDeviceBridgeClient,
        registry: NectoPluginRegistry
    ) async {
        switch envelope.type {
        case .pluginEvent:
            guard let event = try? envelope.decode(NectoPluginEvent.self) else { return }
            await events.route(event, from: target)

        case .pluginRegister:
            guard let registration = try? envelope.decode(NectoPluginRegistration.self) else { return }
            await registry.setDeviceProviders(
                registration.catalog.bridges.map {
                    NectoDeviceBridgeProvider(contract: $0, target: target, appBridge: appBridge)
                },
                for: target,
                pluginID: registration.pluginID
            )

        case .pluginResult:
            guard let result = try? envelope.decode(NectoPluginResult.self) else { return }
            await appBridge.receive(result)

        // The app never receives these, so an app sending one is an SDK bug.
        case .pluginInvoke, .pluginCancel:
            break
        }
    }

    // MARK: Device plugin lifecycle

    /// Called for every plugin registration an app sends. The bridges were already
    /// wired up in `route`; this is about the panel the registration may carry.
    private func receivedRegistration(_ registration: NectoPluginRegistration, from target: NectoTarget) async {
        // An empty registration is how a plugin is taken away.
        if registration.catalog.bridges.isEmpty, registration.panel == nil {
            await removeDevicePlugins { $0.plugin.id == registration.pluginID && $0.target == target }
            return
        }
        guard let stamp = registration.panel else { return }

        let app = connectedApps.first { $0.target == target }
        let appName = app?.appName ?? target.appBundleID

        do {
            let plugin = try await deviceStore.plugin(
                pluginID: registration.pluginID,
                stamp: stamp,
                appName: appName,
                appBundleID: target.appBundleID
            ) { [appBridge] in
                let output = try await appBridge.invoke(
                    name: NectoPanelArchive.fetchBridge.name,
                    version: NectoPanelArchive.fetchBridge.version,
                    kind: .once,
                    input: .object(["pluginID": .string(registration.pluginID)]),
                    target: target
                )
                return try NectoPanelArchive(jsonValue: output)
            }
            await offer(DiscoveredPlugin(plugin: plugin, target: target))
        } catch {
            await log(
                .failure,
                .plugin,
                "The panel of '\(registration.pluginID)' could not be fetched",
                detail: String(describing: error)
            )
        }
    }

    private func offer(_ discovered: DiscoveredPlugin) async {
        // Apps re-register on every connect; the same panel from the same app is news
        // only once.
        if devicePlugins.contains(where: {
            $0.target == discovered.target && $0.plugin.rootURL == discovered.plugin.rootURL
        }) {
            return
        }

        // A plugin in the plugins folder wins over the same id carried by an app:
        // that folder is the developer override, and the day the two collide is the
        // day someone is working on exactly this panel.
        if plugins.contains(where: { $0.id == discovered.id }) {
            await log(.info, .plugin, "'\(discovered.id)' from \(appLabel(of: discovered)) is shadowed by an installed plugin")
            return
        }
        await activate(discovered)
    }

    private func activate(_ discovered: DiscoveredPlugin) async {
        do {
            if let previous = devicePlugins.first(where: {
                $0.id == discovered.id && $0.target == discovered.target
            }), previous.plugin.rootURL != discovered.plugin.rootURL {
                let principal = NectoPluginPrincipal(
                    pluginID: discovered.id,
                    sourceIdentity: "device:\(discovered.target.appBundleID)"
                )
                shellAccess.cancelRequests(for: principal)
            }
            // Each target owns its carried manifest. A second device can be on a
            // different app build without replacing or hiding this one.
            try await registry.installDevice(
                manifest: discovered.plugin.manifest,
                sourceIdentity: "device:\(discovered.target.appBundleID)",
                for: discovered.target
            )
            await shellAccess.registerContentIdentity(
                discovered.plugin.contentIdentity,
                for: NectoPluginPrincipal(
                    pluginID: discovered.id,
                    sourceIdentity: "device:\(discovered.target.appBundleID)"
                )
            )
            devicePlugins.removeAll { $0.id == discovered.id && $0.target == discovered.target }
            devicePlugins.append(discovered)
            devicePlugins.sort { $0.plugin.manifest.name < $1.plugin.manifest.name }
            await log(.info, .plugin, "\(discovered.plugin.manifest.name) arrived from \(appLabel(of: discovered))")
        } catch {
            await log(.failure, .plugin, "\(discovered.plugin.manifest.name) could not be registered", detail: String(describing: error))
        }
    }

    private func dropDevicePlugins(for target: NectoTarget) async {
        await removeDevicePlugins { $0.target == target }
    }

    private func removeDevicePlugins(where matches: (DiscoveredPlugin) -> Bool) async {
        let removed = devicePlugins.filter(matches)
        guard !removed.isEmpty else { return }

        devicePlugins.removeAll(where: matches)
        for discovered in removed {
            shellAccess.cancelRequests(for: NectoPluginPrincipal(
                pluginID: discovered.id,
                sourceIdentity: "device:\(discovered.target.appBundleID)"
            ))
            await registry.uninstallDevice(pluginID: discovered.id, for: discovered.target)
        }

    }

    private func appLabel(of discovered: DiscoveredPlugin) -> String {
        if case let .device(appName, _) = discovered.plugin.source { return appName }
        return discovered.target.appBundleID
    }

    /// Lets the app bridge client reach a connected app without pulling the transport into it.
    private struct Messenger: NectoDeviceMessenger {
        let connections: NectoConnectionCenter

        func send(_ envelope: NectoEnvelope, to target: NectoTarget) async throws {
            try await connections.send(envelope, to: target)
        }
    }

    /// Describes connected apps for the target bridges, without handing the transport's
    /// own model to a plugin.
    private struct TargetSource: NectoTargetSource {
        let connections: NectoConnectionCenter

        var targets: [NectoTargetSummary] {
            get async { await connections.connectedApps.map(Self.summary) }
        }

        func updates() async -> AsyncStream<[NectoTargetSummary]> {
            let apps = await connections.updates()

            return AsyncStream { continuation in
                let task = Task {
                    for await apps in apps {
                        continuation.yield(apps.map(Self.summary))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private static func summary(_ app: NectoConnectedApp) -> NectoTargetSummary {
            NectoTargetSummary(
                target: app.target,
                name: app.deviceName,
                appName: app.appName,
                appBundleID: app.appBundleID,
                deviceType: app.connection == .simulator ? "simulator" : "device",
                // Everything the connection centre reports is by definition attached.
                isConnected: true,
                nectoVersion: app.sdkVersion
            )
        }
    }

    private func registerHostProviders() async {
        for action in ["requestAuthorization", "status", "show"] {
            await registry.registerHostProvider(NectoNotificationProvider(action: action))
        }
        await registry.registerHostProvider(NectoBackgroundProvider())
        await registry.registerHostProvider(NectoHostInfoProvider(nectoVersion: Self.nectoVersion))
        await registry.registerHostProvider(NectoFileSaveProvider())
        await registry.registerHostProvider(NectoFileRevealProvider())
        await registry.registerHostProvider(NectoHostTicksProvider())
        let shell = NectoShellExecuteProvider(policy: shellAccess.policy)
        await registry.registerHostProvider(shell)
        await registry.registerHostProvider(shell.supportingStandardInput())
        await registry.registerHostProvider(
            NectoShellAuthorizationProvider(requester: shellAccess)
        )

        await registry.registerHostProvider(NectoStorageGetProvider(storage: storage))
        await registry.registerHostProvider(NectoStorageSetProvider(storage: storage))
        await registry.registerHostProvider(NectoStorageRemoveProvider(storage: storage))
        await registry.registerHostProvider(NectoStorageKeysProvider(storage: storage))

        let targets = TargetSource(connections: connections)
        await registry.registerHostProvider(
            NectoTargetsListProvider(source: targets, handles: Self.targetHandles)
        )
        await registry.registerHostProvider(
            NectoTargetsObserveProvider(source: targets, handles: Self.targetHandles)
        )
    }

    private func registerCLIPlugin() async {
        let execute = NectoShellExecuteProvider(policy: shellAccess.policy)
        let descriptor = execute.descriptor
        let operation = NectoOperation(
            id: NectoCLIShell.operationID,
            title: "Run shell command",
            description: "Runs one Bash command through Necto's shell policy.",
            kind: descriptor.kind,
            binding: descriptor.binding,
            inputSchema: descriptor.inputSchema,
            outputSchema: descriptor.outputSchema,
            timeoutMs: 30_000
        )
        let manifest = NectoPluginManifest(
            id: NectoCLIShell.pluginID,
            name: "necto-cli",
            description: "The command-line surface of Necto.",
            version: Self.nectoVersion.description,
            author: "Necto",
            icon: .init(systemName: "terminal"),
            assets: [],
            allowedOrigins: ["self"],
            operations: [operation]
        )
        do {
            try await registry.install(
                manifest: manifest,
                sourceIdentity: NectoCLIShell.sourceIdentity
            )
            await shellAccess.registerContentIdentity(
                Self.nectoVersion.description,
                for: NectoShellIdentity.cli
            )
        } catch {
            await log(.failure, .plugin, "necto-cli could not register shell access", detail: String(describing: error))
        }
    }

    private func loadPlugins() async {
        // The registry refuses a second install of the same id, so a reload has to take
        // the previous registration out first. Without this every plugin fails the
        // moment the list is refreshed.
        for plugin in plugins {
            if let principal = plugin.principal { shellAccess.cancelRequests(for: principal) }
            await registry.uninstall(pluginID: plugin.id)
        }

        let installedScan = NectoPluginLibrary.loadInstalled()
        let found = installedScan.plugins
        var failures = installedScan.failures
        var awaitingApproval: [NectoInstalledPlugin] = []

        var records = NectoPluginLibrary.installations
        var grants = NectoPluginLibrary.grants
        for (id, record) in records {
            let exists = FileManager.default.fileExists(atPath: record.directoryPath)
            let changedID = found.contains { $0.rootURL.path == record.directoryPath && $0.id != id }
            if !exists || changedID {
                records.removeValue(forKey: id)
                grants.revoke(record.principal)
                shellAccess.cancelRequests(for: record.principal)
                await shellAccess.forget(record.principal)
            }
        }
        NectoPluginLibrary.installations = records
        NectoPluginLibrary.grants = grants

        var installed: [NectoInstalledPlugin] = []

        for plugin in found {
            // An id is claimed once. A second plugin claiming it would quietly shadow
            // the first, and which one won would depend on scan order.
            guard found.filter({ $0.id == plugin.id }).count == 1 else {
                failures[plugin.manifest.name] = NectoL10n.format(
                    "Another plugin already uses the id '%@'",
                    plugin.id
                )
                continue
            }

            guard let record = plugin.installation,
                  record.approvedContentHash == plugin.contentIdentity else {
                awaitingApproval.append(plugin)
                continue
            }
            let principal = record.principal

            // It is here because someone read what it binds to and said yes; an update
            // that widened its manifest has not been agreed to for the new part.
            let wanted = Set(plugin.manifest.operations.map(\.binding.identity))
            let outstanding = NectoPluginLibrary.grants.unapproved(wanted, for: principal)

            guard outstanding.isEmpty else {
                awaitingApproval.append(plugin)
                continue
            }

            do {
                try await registry.install(
                    manifest: plugin.manifest,
                    sourceIdentity: principal.sourceIdentity
                )
                await shellAccess.registerContentIdentity(
                    plugin.contentIdentity,
                    for: principal
                )
                installed.append(plugin)
            } catch {
                failures[plugin.manifest.name] = String(describing: error)
            }
        }

        plugins = NectoPluginLibrary.sorted(installed)
        pluginsAwaitingApproval = awaitingApproval
        pluginFailures = failures

        for (name, reason) in failures {
            await log(.failure, .plugin, "\(name) did not load", detail: reason)
        }
        await log(.info, .plugin, "\(plugins.count) plugins loaded")
    }

    /// Picks up a folder dropped into the plugins directory without a relaunch.
    func reloadPlugins() async {
        await installer.reloadPlugins()
    }

    /// Called only while the coordinator owns reload or installation commit.
    private func reloadPluginCatalog() async {
        await loadPlugins()

    }
}
