//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoCLIService
import NectoMacService
import NectoModel
import Foundation

/// The control socket's answers, taken from the same places the GUI takes its own.
///
/// Nothing here decides anything: targets come from the connection center's state,
/// operations from the registry, and operation calls use the same validation and
/// providers a panel would see. Installation is forwarded to the app's existing
/// installer and native approval flow.
struct NectoControlBridge: NectoControlHandling {
    let registry: NectoPluginRegistry
    /// Read on demand rather than copied in, so the CLI sees connections as they are.
    let connectedApps: @Sendable () async -> [NectoConnectedApp]
    var install: @Sendable (NectoPluginInstallSource) async throws -> NectoJSONValue = { _ in
        throw NectoBridgeError(code: .operationUnavailable, message: "Plugin installation is unavailable.")
    }
    var delete: @Sendable (String) async throws -> NectoJSONValue = { _ in
        throw NectoBridgeError(code: .operationUnavailable, message: "Plugin deletion is unavailable.")
    }

    func deletePlugin(id: String) async throws -> NectoJSONValue { try await delete(id) }

    func installPlugin(from source: NectoPluginInstallSource) async throws -> NectoJSONValue {
        try await install(source)
    }

    func targets() async -> NectoJSONValue {
        let apps = await connectedApps()
        return ["targets": .array(apps.map { app in
            [
                "appBundleID": .string(app.appBundleID),
                "appName": .string(app.appName),
                "deviceID": .string(app.target.deviceID),
                "deviceName": .string(app.deviceName),
            ]
        })]
    }

    /// The installed manifests, whole. This is the discovery surface: `plugin list`
    /// and `plugin schema` are both readings of this one answer.
    func plugins() async -> NectoJSONValue {
        let installed = await registry.installedPlugins
        let encoded = installed.compactMap { plugin -> NectoJSONValue? in
            guard let operations = try? NectoJSONValue(encoding: plugin.manifest.operations) else { return nil }
            return [
                "id": .string(plugin.manifest.id),
                "name": .string(plugin.manifest.name),
                "version": .string(plugin.manifest.version),
                "description": .string(plugin.manifest.description),
                "operations": operations,
            ]
        }
        return ["plugins": .array(encoded)]
    }

    func invoke(
        pluginID: String,
        operationID: String,
        input: NectoJSONValue,
        app: String?,
        device: String?
    ) async throws -> NectoJSONValue {
        let target = await registry.operationRequiresTarget(
            pluginID: pluginID,
            operationID: operationID
        ) == true ? try await resolveTarget(app: app, device: device) : nil
        return try await registry.invoke(
            pluginID: pluginID,
            operationID: operationID,
            input: input,
            target: target
        )
    }

    func subscribe(
        pluginID: String,
        operationID: String,
        input: NectoJSONValue,
        app: String?,
        device: String?,
        onEvent: @escaping @Sendable (NectoJSONValue) -> Void
    ) async throws {
        let target = await registry.operationRequiresTarget(
            pluginID: pluginID,
            operationID: operationID
        ) == true ? try await resolveTarget(app: app, device: device) : nil
        let stream = try await registry.subscribe(
            pluginID: pluginID,
            operationID: operationID,
            input: input,
            target: target
        )
        for try await event in stream {
            onEvent(event)
        }
    }

    /// The CLI has no sidebar, so the target is named or unambiguous — never guessed.
    private func resolveTarget(app: String?, device: String?) async throws -> NectoTarget? {
        var candidates = await connectedApps()

        if let app {
            candidates = candidates.filter { $0.appBundleID == app }
            guard !candidates.isEmpty else {
                throw NectoBridgeError(
                    code: .targetDisconnected,
                    message: "No connected app has the bundle id '\(app)'"
                )
            }
        }
        if let device {
            candidates = candidates.filter { $0.target.deviceID == device }
            guard !candidates.isEmpty else {
                throw NectoBridgeError(
                    code: .targetDisconnected,
                    message: "No connected device has the id '\(device)'"
                )
            }
        }

        // Several left is a question that must be asked back rather than answered by
        // luck — with the flag that actually disambiguates what remains.
        if candidates.count > 1 {
            let bundles = Set(candidates.map(\.appBundleID))
            if bundles.count > 1 {
                throw NectoBridgeError(
                    code: .invalidInput,
                    message: "Several apps are connected; pass --app with one of: \(bundles.sorted().joined(separator: ", "))"
                )
            }
            let devices = candidates.map(\.target.deviceID).sorted()
            throw NectoBridgeError(
                code: .invalidInput,
                message: "'\(candidates[0].appBundleID)' runs on several devices; pass --device with one of: \(devices.joined(separator: ", "))"
            )
        }
        return candidates.first?.target
    }
}
