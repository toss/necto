//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoCLIService
import NectoModel
import Foundation

/// CLI discovery and execution share an explicit plugin ownership scope.
public struct NectoControlBridge: NectoControlHandling {
    private let registry: NectoPluginRegistry
    private let connectedApps: @Sendable () async -> [NectoConnectedApp]
    private let install: @Sendable (NectoPluginInstallSource) async throws -> NectoJSONValue
    private let delete: @Sendable (String) async throws -> NectoJSONValue

    public init(
        registry: NectoPluginRegistry,
        connectedApps: @escaping @Sendable () async -> [NectoConnectedApp],
        install: @escaping @Sendable (NectoPluginInstallSource) async throws -> NectoJSONValue = { _ in
            throw NectoBridgeError(code: .operationUnavailable, message: "Plugin installation is unavailable.")
        },
        delete: @escaping @Sendable (String) async throws -> NectoJSONValue = { _ in
            throw NectoBridgeError(code: .operationUnavailable, message: "Plugin deletion is unavailable.")
        }
    ) {
        self.registry = registry
        self.connectedApps = connectedApps
        self.install = install
        self.delete = delete
    }

    public func deletePlugin(id: String) async throws -> NectoJSONValue { try await delete(id) }

    public func installPlugin(from source: NectoPluginInstallSource) async throws -> NectoJSONValue {
        try await install(source)
    }

    public func targets() async -> NectoJSONValue {
        let apps = await connectedApps()
        return ["targets": .array(apps.sorted { $0.id < $1.id }.map { app in
            [
                "appBundleID": .string(app.appBundleID),
                "appName": .string(app.appName),
                "deviceID": .string(app.target.deviceID),
                "deviceName": .string(app.deviceName),
            ]
        })]
    }

    public func plugins(
        app: String?, device: String?, desktop: Bool,
        pluginID: String? = nil, operationID: String? = nil
    ) async throws -> NectoJSONValue {
        guard operationID == nil || pluginID != nil else {
            throw NectoBridgeError(code: .invalidInput, message: "An operation ID requires a plugin ID.")
        }
        let target = try await resolveTarget(app: app, device: device, desktop: desktop)
        let plugins = await registry.installedPlugins(for: target)
        var result: [String: NectoJSONValue] = [
            "scope": .string(desktop ? "desktop" : "device"),
            "target": target.map { ["deviceID": .string($0.deviceID), "appBundleID": .string($0.appBundleID)] } ?? .null,
        ]
        guard let pluginID else {
            result["plugins"] = .array(plugins.map { metadata($0.manifest) })
            return .object(result)
        }
        let plugin = try requirePlugin(pluginID, in: plugins)
        let context = await registry.context(pluginID: pluginID, target: target, expectedPrincipal: plugin.principal)
        guard let context else {
            throw NectoBridgeError(code: .operationUnavailable, message: "The plugin changed during discovery. Retry the same target.")
        }
        func operationInfo(_ operation: NectoOperation, schemas: Bool) -> NectoJSONValue {
            var info: [String: NectoJSONValue] = [
                "id": .string(operation.id), "title": .string(operation.title),
                "description": .string(operation.description), "kind": .string(operation.kind.rawValue),
                "timeoutMs": .number(Double(operation.timeoutMs)),
            ]
            let availability = context.operations.first { $0.id == operation.id }
            info["available"] = .bool(availability?.available == true)
            if let reason = availability?.unavailableReason { info["unavailableReason"] = .string(reason) }
            if schemas {
                info["inputSchema"] = operation.inputSchema
                info["outputSchema"] = operation.outputSchema
            }
            return .object(info)
        }
        var detail = metadata(plugin.manifest).objectValue ?? [:]
        if let operationID {
            guard let operation = plugin.manifest.operation(id: operationID) else {
                throw NectoBridgeError(code: .operationNotFound, message: "No operation '\(operationID)' in '\(pluginID)'. Read plugin help for this target.")
            }
            result["operation"] = operationInfo(operation, schemas: true)
        } else {
            detail["operations"] = .array(plugin.manifest.operations.map { operationInfo($0, schemas: false) })
        }
        result["plugin"] = .object(detail)
        return .object(result)
    }

    public func invoke(
        pluginID: String, operationID: String, input: NectoJSONValue,
        app: String?, device: String?, desktop: Bool
    ) async throws -> NectoJSONValue {
        let target = try await resolveTarget(app: app, device: device, desktop: desktop)
        let plugin = try await requirePlugin(pluginID, in: registry.installedPlugins(for: target))
        return try await registry.invoke(
            pluginID: pluginID, operationID: operationID, input: input,
            target: target, expectedPrincipal: plugin.principal
        )
    }

    public func subscribe(
        pluginID: String, operationID: String, input: NectoJSONValue,
        app: String?, device: String?, desktop: Bool,
        onEvent: @escaping @Sendable (NectoJSONValue) -> Void
    ) async throws {
        let target = try await resolveTarget(app: app, device: device, desktop: desktop)
        let plugin = try await requirePlugin(pluginID, in: registry.installedPlugins(for: target))
        let stream = try await registry.subscribe(
            pluginID: pluginID, operationID: operationID, input: input,
            target: target, expectedPrincipal: plugin.principal
        )
        for try await event in stream { onEvent(event) }
    }

    private func metadata(_ manifest: NectoPluginManifest) -> NectoJSONValue {
        ["id": .string(manifest.id), "name": .string(manifest.name),
         "version": .string(manifest.version), "description": .string(manifest.description)]
    }

    private func requirePlugin(_ id: String, in plugins: [NectoPluginRegistry.InstalledPlugin]) throws -> NectoPluginRegistry.InstalledPlugin {
        guard let plugin = plugins.first(where: { $0.manifest.id == id }) else {
            throw NectoBridgeError(code: .operationNotFound, message: "No plugin '\(id)' in this scope. Run plugin list with the same target flags.")
        }
        return plugin
    }

    private func resolveTarget(app: String?, device: String?, desktop: Bool) async throws -> NectoTarget? {
        if desktop {
            guard app == nil, device == nil else {
                throw NectoBridgeError(code: .invalidInput, message: "--desktop cannot be combined with --app or --device.")
            }
            return nil
        }
        let apps = await connectedApps()
        guard let app, !app.isEmpty, let device, !device.isEmpty else {
            let candidates = apps.sorted { $0.id < $1.id }.map { "\($0.target.deviceID) / \($0.appBundleID)" }.joined(separator: ", ")
            throw NectoBridgeError(code: .invalidInput, message: "Pass both --device and --app, or --desktop. Run necto device list. Connected targets: \(candidates.isEmpty ? "none" : candidates)")
        }
        let matches = apps.filter { $0.appBundleID == app && $0.target.deviceID == device }
        guard matches.count == 1, let match = matches.first else {
            throw NectoBridgeError(code: .targetDisconnected, message: "No unique connected app '\(app)' on device '\(device)'. Run necto device list.")
        }
        return match.target
    }
}
