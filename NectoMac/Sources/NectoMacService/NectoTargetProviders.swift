//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// What a plugin is allowed to know about a connected app.
///
/// Deliberately not the transport's own model: a plugin sees a handle and description,
/// never a device id it could use to address something it was not shown.
public struct NectoTargetSummary: Sendable, Hashable {
    public let target: NectoTarget
    public let name: String
    public let appName: String
    public let appBundleID: String
    public let deviceType: String
    public let isConnected: Bool
    public let nectoVersion: String?

    public init(
        target: NectoTarget,
        name: String,
        appName: String,
        appBundleID: String,
        deviceType: String,
        isConnected: Bool,
        nectoVersion: String? = nil
    ) {
        self.target = target
        self.name = name
        self.appName = appName
        self.appBundleID = appBundleID
        self.deviceType = deviceType
        self.isConnected = isConnected
        self.nectoVersion = nectoVersion
    }
}

/// Where the target bridges read from. The Mac app implements it over its connections.
public protocol NectoTargetSource: Sendable {
    var targets: [NectoTargetSummary] { get async }

    /// Emits the full list whenever it changes, starting with the current one.
    func updates() async -> AsyncStream<[NectoTargetSummary]>
}

/// Lists the apps a plugin may point at.
public struct NectoTargetsListProvider: NectoOperationProvider {
    public static let key = "necto.desktop.targets.list"

    public let descriptor = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: key, version: 1),
        kind: .once
    )

    private let source: any NectoTargetSource
    private let handles: NectoTargetHandles

    public init(source: any NectoTargetSource, handles: NectoTargetHandles) {
        self.source = source
        self.handles = handles
    }

    public func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        let includeDiscovered = input["includeDiscovered"]?.boolValue ?? false
        let summaries = await source.targets.filter { includeDiscovered || $0.isConnected }

        return await [
            "targets": .array(NectoTargetCoding.json(summaries, for: context.principal, handles: handles)),
        ]
    }
}

/// Streams the list whenever it changes.
public struct NectoTargetsObserveProvider: NectoOperationProvider {
    public static let key = "necto.desktop.targets.observe"

    public let descriptor = NectoBridgeDescriptor(
        binding: NectoBridgeBinding(name: key, version: 1),
        kind: .stream
    )

    private let source: any NectoTargetSource
    private let handles: NectoTargetHandles

    public init(source: any NectoTargetSource, handles: NectoTargetHandles) {
        self.source = source
        self.handles = handles
    }

    public func subscribe(
        input: NectoJSONValue,
        context: NectoInvocationContext
    ) async throws -> AsyncThrowingStream<NectoJSONValue, any Error> {
        let includeDiscovered = input["includeDiscovered"]?.boolValue ?? false
        let updates = await source.updates()
        let principal = context.principal
        let handles = handles

        return AsyncThrowingStream { continuation in
            let task = Task {
                for await summaries in updates {
                    let visible = summaries.filter { includeDiscovered || $0.isConnected }
                    let targets = await NectoTargetCoding.json(visible, for: principal, handles: handles)
                    continuation.yield(["targets": .array(targets)])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum NectoTargetCoding {
    static func json(
        _ summaries: [NectoTargetSummary],
        for principal: NectoPluginPrincipal,
        handles: NectoTargetHandles
    ) async -> [NectoJSONValue] {
        var targets: [NectoJSONValue] = []

        for summary in summaries {
            let handle = await handles.handle(for: summary.target, principal: principal)
            var object: [String: NectoJSONValue] = [
                "targetHandle": .string(handle),
                "name": .string(summary.name),
                "appName": .string(summary.appName),
                "appBundleID": .string(summary.appBundleID),
                "deviceType": .string(summary.deviceType),
                "isConnected": .bool(summary.isConnected),
            ]
            if let nectoVersion = summary.nectoVersion {
                object["nectoVersion"] = .string(nectoVersion)
            }
            targets.append(.object(object))
        }
        return targets
    }
}
