//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// Owns installed plugins and registered providers, and routes operation calls.
///
/// Web panels and the CLI reach the same provider through this registry.
/// No surface gets a private bypass.
public actor NectoPluginRegistry {
    public struct InstalledPlugin: Sendable {
        public let manifest: NectoPluginManifest
        public let principal: NectoPluginPrincipal
    }

    public enum InstallError: Sendable, Error, Equatable, CustomStringConvertible {
        case validation(NectoManifestValidationError)
        case alreadyInstalled(String)

        public var description: String {
            switch self {
            case let .validation(error): error.description
            case let .alreadyInstalled(id): "'\(id)' is already installed."
            }
        }
    }

    private var installed: [String: InstalledPlugin] = [:]
    /// Device-carried manifests are scoped to their target. Two connected devices can
    /// run different builds of the same app without either panel shadowing the other.
    private var deviceInstalled: [NectoTarget: [String: InstalledPlugin]] = [:]
    private var hostProviders: [String: any NectoOperationProvider] = [:]
    /// Grouped by the plugin that declared them, so one plugin's catalog can be
    /// replaced without disturbing another's on the same app.
    private var deviceProviders: [NectoTarget: [String: [String: [any NectoOperationProvider]]]] = [:]
    private struct InvocationRoute: Hashable, Sendable {
        let principal: NectoPluginPrincipal
        let binding: String
        let target: NectoTarget?
    }
    private struct Invocation: Sendable {
        let route: InvocationRoute
        let work: Task<Void, Never>
        let timer: Task<Void, Never>?
        var reply: CheckedContinuation<NectoJSONValue, any Error>?
    }
    /// A returned deadline cancels work but retains its slot until the provider exits.
    /// Retries cannot accumulate more stuck work on that same route.
    private var invocations: [UUID: Invocation] = [:]
    private struct Subscription: Sendable {
        let route: InvocationRoute
        let startup: Task<AsyncThrowingStream<NectoJSONValue, any Error>, any Error>
        var forwarding: Task<Void, Never>?
        var continuation: AsyncThrowingStream<NectoJSONValue, any Error>.Continuation?

        func cancel() {
            startup.cancel()
            forwarding?.cancel()
            continuation?.finish(throwing: CancellationError())
        }
    }
    private var subscriptions: [UUID: Subscription] = [:]
    /// Shared with the target bridges, so a handle issued here is the same one a
    /// plugin may pass back to `necto.targets.*`.
    public let targetHandles: NectoTargetHandles

    public init(targetHandles: NectoTargetHandles = NectoTargetHandles()) {
        self.targetHandles = targetHandles
    }

    deinit {
        for subscription in subscriptions.values { subscription.cancel() }
        for invocation in invocations.values {
            invocation.work.cancel()
            invocation.timer?.cancel()
            invocation.reply?.resume(throwing: CancellationError())
        }
    }

    /// Registers a manifest after host approval. Calls still validate the route,
    /// principal and schemas; providers enforce additional permissions such as shell access.
    @discardableResult
    public func install(
        manifest: NectoPluginManifest,
        sourceIdentity: String
    ) throws(InstallError) -> InstalledPlugin {
        do {
            try manifest.validate()
        } catch {
            throw .validation(error)
        }

        guard installed[manifest.id] == nil else {
            throw .alreadyInstalled(manifest.id)
        }

        let plugin = InstalledPlugin(
            manifest: manifest,
            principal: NectoPluginPrincipal(pluginID: manifest.id, sourceIdentity: sourceIdentity)
        )
        installed[manifest.id] = plugin
        return plugin
    }

    public func uninstall(pluginID: String) {
        guard let plugin = installed.removeValue(forKey: pluginID) else { return }
        let principal = plugin.principal
        cancelInvocations(principal: principal)
        Task { await targetHandles.forget(principal: principal) }
    }

    /// Registers or replaces the manifest carried by one connected target.
    @discardableResult
    public func installDevice(
        manifest: NectoPluginManifest,
        sourceIdentity: String,
        for target: NectoTarget
    ) throws(InstallError) -> InstalledPlugin {
        do {
            try manifest.validate()
        } catch {
            throw .validation(error)
        }

        let plugin = InstalledPlugin(
            manifest: manifest,
            principal: NectoPluginPrincipal(pluginID: manifest.id, sourceIdentity: sourceIdentity)
        )
        if let previous = deviceInstalled[target]?[manifest.id] {
            cancelInvocations(principal: previous.principal, target: target)
        }
        deviceInstalled[target, default: [:]][manifest.id] = plugin
        return plugin
    }

    public func uninstallDevice(pluginID: String, for target: NectoTarget) {
        guard let plugin = deviceInstalled[target]?.removeValue(forKey: pluginID) else { return }
        if deviceInstalled[target]?.isEmpty == true {
            deviceInstalled.removeValue(forKey: target)
        }

        let principal = plugin.principal
        cancelInvocations(principal: principal, target: target)
        let isStillInstalled = installed.values.contains { $0.principal == principal }
            || deviceInstalled.values.contains { $0.values.contains { $0.principal == principal } }
        if !isStillInstalled {
            Task { await targetHandles.forget(principal: principal) }
        }
    }

    public func plugin(id pluginID: String, target: NectoTarget? = nil) -> InstalledPlugin? {
        if let target, let plugin = deviceInstalled[target]?[pluginID] {
            return plugin
        }
        return installed[pluginID]
    }

    public var installedPlugins: [InstalledPlugin] {
        var unique = installed
        let carried = deviceInstalled.values
            .flatMap(\.values)
            .sorted {
                ($0.manifest.id, $0.manifest.version) < ($1.manifest.id, $1.manifest.version)
            }
        for plugin in carried where unique[plugin.manifest.id] == nil {
            unique[plugin.manifest.id] = plugin
        }
        return unique.values.sorted { $0.manifest.id < $1.manifest.id }
    }

    /// An exact ownership scope, without falling back to another app or desktop installation.
    public func installedPlugins(for target: NectoTarget?) -> [InstalledPlugin] {
        let plugins = target.map { deviceInstalled[$0] ?? [:] } ?? installed
        return plugins.values.sorted { $0.manifest.id < $1.manifest.id }
    }

    public func registerHostProvider(_ provider: any NectoOperationProvider) {
        hostProviders[provider.descriptor.identity] = provider
    }

    /// What a plugin offers *now*, replacing whatever it offered before.
    ///
    /// An app registers by declaring its whole catalog rather than adding to one, so a
    /// plugin the app removed leaves with an empty catalog and no message of its own.
    /// Re-registering after a reconnection is the same call and stays correct.
    public func setDeviceProviders(
        _ providers: [any NectoOperationProvider],
        for target: NectoTarget,
        pluginID: String
    ) {
        guard !providers.isEmpty else {
            deviceProviders[target]?.removeValue(forKey: pluginID)
            return
        }

        let groups = Dictionary(grouping: providers, by: { $0.descriptor.identity })
        deviceProviders[target, default: [:]][pluginID] = groups
    }

    /// Drops every provider for a target once its app disconnects.
    public func unregisterDeviceProviders(for target: NectoTarget) {
        deviceProviders.removeValue(forKey: target)
    }

    /// Builds the value returned by `NectoBridge.context()`.
    public func context(
        pluginID: String,
        target: NectoTarget?,
        targetName: String? = nil,
        appName: String? = nil,
        expectedPrincipal: NectoPluginPrincipal? = nil
    ) async -> NectoPluginContext? {
        guard let plugin = plugin(id: pluginID, target: target) else { return nil }
        guard expectedPrincipal == nil || expectedPrincipal == plugin.principal else { return nil }

        let operations = plugin.manifest.operations.map { operation in
            let failure = unavailableReason(for: operation, plugin: plugin, target: target)
            return NectoAvailableOperation(
                id: operation.id,
                kind: operation.kind,
                available: failure == nil,
                unavailableReason: failure
            )
        }

        var info: NectoTargetInfo?
        if let target {
            info = await NectoTargetInfo(
                targetHandle: targetHandles.handle(for: target, principal: plugin.principal),
                appBundleID: target.appBundleID,
                name: targetName,
                appName: appName
            )
        }

        return NectoPluginContext(
            pluginID: plugin.manifest.id,
            pluginVersion: plugin.manifest.version,
            sourceIdentity: plugin.principal.sourceIdentity,
            operations: operations,
            target: info
        )
    }

    public func invoke(
        pluginID: String,
        operationID: String,
        input: NectoJSONValue = .object([:]),
        target: NectoTarget?,
        expectedPrincipal: NectoPluginPrincipal? = nil
    ) async throws -> NectoJSONValue {
        let resolved = try resolve(
            pluginID: pluginID,
            operationID: operationID,
            target: target,
            expecting: [.once],
            expectedPrincipal: expectedPrincipal
        )
        try validateInput(input, for: resolved.operation)

        let context = NectoInvocationContext(
            principal: resolved.plugin.principal,
            target: target
        )

        let output: NectoJSONValue
        do {
            output = try await withTimeout(
                milliseconds: resolved.operation.timeoutMs, operationID: operationID,
                route: InvocationRoute(principal: context.principal,
                                       binding: resolved.operation.binding.identity, target: target)
            ) {
                try await resolved.provider.invoke(input: input, context: context)
            }
        } catch let error as NectoBridgeError {
            throw error
        } catch {
            throw NectoBridgeError(
                code: .providerFailed,
                message: String(describing: error),
                operationID: operationID
            )
        }

        if let failure = NectoJSONSchema.validate(output, against: resolved.operation.outputSchema) {
            throw NectoBridgeError(
                code: .invalidOutput,
                message: failure.description,
                operationID: operationID
            )
        }
        return output
    }

    public func subscribe(
        pluginID: String,
        operationID: String,
        input: NectoJSONValue = .object([:]),
        target: NectoTarget?,
        expectedPrincipal: NectoPluginPrincipal? = nil
    ) async throws -> AsyncThrowingStream<NectoJSONValue, any Error> {
        let resolved = try resolve(
            pluginID: pluginID,
            operationID: operationID,
            target: target,
            expecting: [.stream],
            expectedPrincipal: expectedPrincipal
        )
        try validateInput(input, for: resolved.operation)

        let context = NectoInvocationContext(
            principal: resolved.plugin.principal,
            target: target
        )
        try Task.checkCancellation()
        let id = UUID()
        let startup = Task { try await resolved.provider.subscribe(input: input, context: context) }
        subscriptions[id] = Subscription(
            route: InvocationRoute(principal: context.principal,
                                   binding: resolved.operation.binding.identity, target: target),
            startup: startup)
        return try await withTaskCancellationHandler {
            do {
                let upstream = try await startup.value
                try Task.checkCancellation()
                // Removal or replacement can happen while the provider opens its stream.
                guard subscriptions[id] != nil else { throw CancellationError() }
                let pair = AsyncThrowingStream<NectoJSONValue, any Error>.makeStream()
                let forwarding = Task { [weak self] in
                    do {
                        for try await event in upstream {
                            try Task.checkCancellation()
                            if let failure = NectoJSONSchema.validate(event, against: resolved.operation.outputSchema) {
                                throw NectoBridgeError(code: .invalidOutput, message: failure.description,
                                                       operationID: operationID)
                            }
                            pair.continuation.yield(event)
                        }
                        pair.continuation.finish()
                    } catch {
                        pair.continuation.finish(throwing: error)
                    }
                    await self?.cancelSubscription(id)
                }
                subscriptions[id]?.forwarding = forwarding
                subscriptions[id]?.continuation = pair.continuation
                pair.continuation.onTermination = { [weak self] _ in
                    forwarding.cancel()
                    Task { await self?.cancelSubscription(id) }
                }
                return pair.stream
            } catch {
                cancelSubscription(id)
                throw error
            }
        } onCancel: {
            startup.cancel()
            Task { await self.cancelSubscription(id) }
        }
    }

    private struct Resolved {
        let plugin: InstalledPlugin
        let operation: NectoOperation
        let provider: any NectoOperationProvider
    }

    private func resolve(
        pluginID: String,
        operationID: String,
        target: NectoTarget?,
        expecting kinds: Set<NectoOperationKind>,
        expectedPrincipal: NectoPluginPrincipal?
    ) throws -> Resolved {
        guard let plugin = plugin(id: pluginID, target: target) else {
            throw NectoBridgeError(
                code: .operationNotFound,
                message: "Plugin '\(pluginID)' is not installed",
                operationID: operationID
            )
        }
        guard expectedPrincipal == nil || expectedPrincipal == plugin.principal else {
            throw NectoBridgeError(
                code: .permissionDenied,
                message: "This panel belongs to a different plugin installation",
                operationID: operationID
            )
        }
        guard let operation = plugin.manifest.operation(id: operationID) else {
            throw NectoBridgeError(
                code: .operationNotFound,
                message: "Plugin '\(pluginID)' declares no operation '\(operationID)'",
                operationID: operationID
            )
        }
        guard kinds.contains(operation.kind) else {
            throw NectoBridgeError(
                code: .operationUnavailable,
                message: "A \(operation.kind.rawValue) operation cannot be called this way",
                operationID: operationID
            )
        }
        if let reason = unavailableReason(for: operation, plugin: plugin, target: target) {
            throw NectoBridgeError(
                code: unavailableCode(for: operation, plugin: plugin, target: target),
                message: reason,
                operationID: operationID
            )
        }
        guard let provider = provider(for: operation, target: target) else {
            throw NectoBridgeError(
                code: .operationUnavailable,
                message: "No provider offers '\(operationID)'",
                operationID: operationID
            )
        }
        return Resolved(plugin: plugin, operation: operation, provider: provider)
    }

    private func unavailableReason(
        for operation: NectoOperation,
        plugin: InstalledPlugin,
        target: NectoTarget?
    ) -> String? {
        if operation.binding.requiresTarget, target == nil {
            return "Select a connected app to use this operation"
        }
        guard let provider = provider(for: operation, target: target) else {
            return operation.binding.requiresTarget
                ? "The selected app does not provide this operation"
                : "No provider offers this operation"
        }
        if let mismatch = provider.descriptor.mismatch(with: operation) {
            return "The provider for '\(operation.binding.name)' \(mismatch)"
        }
        return nil
    }

    private func unavailableCode(
        for operation: NectoOperation,
        plugin: InstalledPlugin,
        target: NectoTarget?
    ) -> NectoBridgeErrorCode {
        if operation.binding.requiresTarget, target == nil {
            return .targetDisconnected
        }
        return .operationUnavailable
    }

    private func provider(
        for operation: NectoOperation,
        target: NectoTarget?
    ) -> (any NectoOperationProvider)? {
        let identity = operation.binding.identity
        switch operation.binding.type {
        case .desktop:
            return hostProviders[identity]
        case .device:
            guard let target else { return nil }
            let matches = deviceProviders[target]?.values.flatMap { $0[identity] ?? [] } ?? []
            return matches.count == 1 ? matches.first : nil
        // A name that says who owns it is checked when the manifest is validated, so
        // there is nothing to look this up in.
        case nil:
            return nil
        }
    }

    private func validateInput(_ input: NectoJSONValue, for operation: NectoOperation) throws {
        if let failure = NectoJSONSchema.validate(input, against: operation.inputSchema) {
            throw NectoBridgeError(
                code: .invalidInput,
                message: failure.description,
                operationID: operation.id
            )
        }
    }

    private func withTimeout(
        milliseconds: Int,
        operationID: String,
        route: InvocationRoute,
        body: @escaping @Sendable () async throws -> NectoJSONValue
    ) async throws -> NectoJSONValue {
        try Task.checkCancellation()
        guard !invocations.values.contains(where: { $0.route == route && $0.reply == nil }) else {
            throw NectoBridgeError(code: .operationUnavailable,
                                   message: "The previous request is still stopping. Try again after it finishes.",
                                   operationID: operationID)
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { reply in
                let work = Task<Void, Never> { [weak self] in
                    let result: Result<NectoJSONValue, any Error>
                    do {
                        try Task.checkCancellation()
                        result = .success(try await body())
                    } catch { result = .failure(error) }
                    await self?.completeInvocation(id, result: result)
                }
                let timer: Task<Void, Never>? = milliseconds > 0 ? Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(milliseconds)) }
                    catch { return }
                    await self?.cancelInvocation(id, error: NectoBridgeError(
                        code: .timeout, message: "The provider did not respond within \(milliseconds)ms",
                        operationID: operationID))
                } : nil
                invocations[id] = Invocation(route: route, work: work, timer: timer, reply: reply)
            }
        } onCancel: {
            Task { await self.cancelInvocation(id, error: CancellationError()) }
        }
    }

    private func completeInvocation(_ id: UUID, result: Result<NectoJSONValue, any Error>) {
        guard let invocation = invocations.removeValue(forKey: id) else { return }
        invocation.timer?.cancel()
        invocation.reply?.resume(with: result)
    }

    private func cancelInvocation(_ id: UUID, error: any Error) {
        guard var invocation = invocations[id], let reply = invocation.reply else { return }
        invocation.reply = nil
        invocations[id] = invocation
        invocation.timer?.cancel()
        invocation.work.cancel()
        reply.resume(throwing: error)
    }

    private func cancelInvocations(principal: NectoPluginPrincipal, target: NectoTarget? = nil) {
        for (id, invocation) in invocations where invocation.route.principal == principal
            && (target == nil || invocation.route.target == target) {
            cancelInvocation(id, error: CancellationError())
        }
        for (id, subscription) in subscriptions where subscription.route.principal == principal
            && (target == nil || subscription.route.target == target) {
            cancelSubscription(id)
        }
    }

    private func cancelSubscription(_ id: UUID) {
        subscriptions.removeValue(forKey: id)?.cancel()
    }
}
