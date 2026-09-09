//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// Sends a message to a connected app. Implemented over the transport by the host.
public protocol NectoDeviceMessenger: Sendable {
    func send(_ envelope: NectoEnvelope, to target: NectoTarget) async throws
}

/// Turns an app contract call into messages and back.
///
/// A contract lives in the connected app, so calling one is a round trip: the host
/// sends `plugin.invoke` and parks the caller until a matching `plugin.result` comes
/// back. `requestID` is what pairs them, and a target that disconnects fails
/// everything still parked rather than leaving callers waiting forever.
public actor NectoDeviceBridgeClient {
    private let messenger: any NectoDeviceMessenger

    private var pending: [String: CheckedContinuation<NectoJSONValue, any Error>] = [:]
    private var streams: [String: AsyncThrowingStream<NectoJSONValue, any Error>.Continuation] = [:]
    /// Which target each request went to, so a disconnect can fail just its own.
    private var targets: [String: NectoTarget] = [:]
    /// Invokes cancelled before their continuation was parked.
    private var cancelledInvokes: Set<String> = []

    public init(messenger: any NectoDeviceMessenger) {
        self.messenger = messenger
    }

    public func invoke(
        name: String,
        version: Int,
        kind: NectoOperationKind,
        input: NectoJSONValue,
        target: NectoTarget
    ) async throws -> NectoJSONValue {
        let requestID = UUID().uuidString

        // Cancellation must resume the parked continuation, or a timed-out call
        // waits on the app forever: the registry's timeout throws, and then its task
        // group awaits this child — which, without the handler, never comes back
        // when the app has stopped answering.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Parked before anything can race to resume it; this closure runs on
                // the actor, so the send task below cannot start sooner.
                begin(requestID: requestID, continuation: continuation, target: target)
                Task {
                    do {
                        try await self.send(requestID: requestID, name: name, version: version, kind: kind, input: input, target: target)
                    } catch {
                        self.resume(requestID: requestID, throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelInvoke(requestID: requestID, target: target) }
        }
    }

    /// Parks the continuation — unless the call was already cancelled, in which case
    /// it is resumed on the spot rather than parked with nobody left to wake it.
    private func begin(
        requestID: String,
        continuation: CheckedContinuation<NectoJSONValue, any Error>,
        target: NectoTarget
    ) {
        if cancelledInvokes.remove(requestID) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        pending[requestID] = continuation
        targets[requestID] = target
    }

    private func cancelInvoke(requestID: String, target: NectoTarget) async {
        guard let continuation = pending.removeValue(forKey: requestID) else {
            // Cancelled before the continuation was parked; `begin` finds this mark.
            cancelledInvokes.insert(requestID)
            return
        }
        targets.removeValue(forKey: requestID)
        continuation.resume(throwing: CancellationError())

        // The app may still be alive and merely slow; telling it saves it the work.
        let cancel = NectoPluginCancel(requestID: requestID)
        try? await messenger.send(NectoEnvelope(type: .pluginCancel, encoding: cancel), to: target)
    }

    public func subscribe(
        name: String,
        version: Int,
        input: NectoJSONValue,
        target: NectoTarget
    ) async throws -> AsyncThrowingStream<NectoJSONValue, any Error> {
        let requestID = UUID().uuidString

        let stream = AsyncThrowingStream<NectoJSONValue, any Error> { continuation in
            streams[requestID] = continuation
            targets[requestID] = target

            continuation.onTermination = { [weak self] _ in
                Task { await self?.cancel(requestID: requestID, target: target) }
            }
        }

        try await send(requestID: requestID, name: name, version: version, kind: .stream, input: input, target: target)
        return stream
    }

    /// Called for every `plugin.result` the transport reads.
    public func receive(_ result: NectoPluginResult) {
        if let stream = streams[result.requestID] {
            if let output = result.output, !result.isFinal {
                stream.yield(output)
                return
            }
            streams.removeValue(forKey: result.requestID)
            targets.removeValue(forKey: result.requestID)
            stream.finish(throwing: result.error)
            return
        }

        guard let continuation = pending.removeValue(forKey: result.requestID) else { return }
        targets.removeValue(forKey: result.requestID)

        if let error = result.error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: result.output ?? .object([:]))
        }
    }

    /// Fails everything still waiting on an app that went away.
    public func targetDisconnected(_ target: NectoTarget) {
        let error = NectoBridgeError(
            code: .targetDisconnected,
            message: "'\(target.appBundleID)' disconnected before answering"
        )

        for (requestID, requestTarget) in targets where requestTarget == target {
            targets.removeValue(forKey: requestID)
            pending.removeValue(forKey: requestID)?.resume(throwing: error)
            streams.removeValue(forKey: requestID)?.finish(throwing: error)
        }
    }

    private func send(
        requestID: String,
        name: String,
        version: Int,
        kind: NectoOperationKind,
        input: NectoJSONValue,
        target: NectoTarget
    ) async throws {
        let invocation = NectoPluginInvocation(
            requestID: requestID,
            name: name,
            version: version,
            kind: kind,
            input: input
        )
        try await messenger.send(NectoEnvelope(type: .pluginInvoke, encoding: invocation), to: target)
    }

    private func cancel(requestID: String, target: NectoTarget) async {
        guard streams.removeValue(forKey: requestID) != nil else { return }
        targets.removeValue(forKey: requestID)

        let cancel = NectoPluginCancel(requestID: requestID)
        try? await messenger.send(NectoEnvelope(type: .pluginCancel, encoding: cancel), to: target)
    }

    private func resume(requestID: String, throwing error: any Error) {
        targets.removeValue(forKey: requestID)
        pending.removeValue(forKey: requestID)?.resume(throwing: error)
    }
}

/// Exposes one app contract to the runtime.
///
/// Registered per target when an app announces its contracts, and dropped when that
/// app disconnects, so the registry only ever offers what is actually reachable.
public struct NectoDeviceBridgeProvider: NectoOperationProvider {
    public let descriptor: NectoBridgeDescriptor

    private let name: String
    private let version: Int
    private let target: NectoTarget
    private let appBridge: NectoDeviceBridgeClient

    /// The app states its own contract, including what it must be approved under, so
    /// a connected app cannot quietly widen what a plugin is allowed to ask it for.
    public init(
        contract: NectoBridgeDescriptor,
        target: NectoTarget,
        appBridge: NectoDeviceBridgeClient
    ) {
        name = contract.name
        version = contract.version
        self.target = target
        self.appBridge = appBridge
        descriptor = contract
    }

    public func invoke(input: NectoJSONValue, context _: NectoInvocationContext) async throws -> NectoJSONValue {
        try await appBridge.invoke(
            name: name,
            version: version,
            kind: descriptor.kind,
            input: input,
            target: target
        )
    }

    public func subscribe(
        input: NectoJSONValue,
        context _: NectoInvocationContext
    ) async throws -> AsyncThrowingStream<NectoJSONValue, any Error> {
        try await appBridge.subscribe(name: name, version: version, input: input, target: target)
    }
}
