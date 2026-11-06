//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// Enriches records and delivers allowed events to one registered exporter.
/// Registration, policy changes and delivery run in one actor turn without an
/// intervening suspension. There is no host replay buffer or delivery queue.
public actor NectoEventDispatcher {
    private struct Exporter {
        let registrationID: UUID
        let receive: @Sendable (NectoEvent) -> Void
    }

    private let installationID: String
    private let nectoVersion: String
    private let now: @Sendable () -> Date
    private var policy: NectoEventCollectionPolicy
    private var exporter: Exporter?

    public init(
        installationID: String,
        nectoVersion: String,
        policy: NectoEventCollectionPolicy = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.installationID = installationID
        self.nectoVersion = nectoVersion
        self.policy = policy
        self.now = now
    }

    /// Called only after the installation UI accepts the exporter registration.
    /// The receiver must accept the event promptly; batching and asynchronous IO
    /// belong to the exporter. Returning transfers ownership of that event to it.
    @discardableResult
    public func registerExporter(
        receive: @escaping @Sendable (NectoEvent) -> Void
    ) throws -> UUID {
        guard exporter == nil else {
            throw NectoBridgeError(code: .operationUnavailable, message: "An exporter is already registered")
        }
        let id = UUID()
        exporter = Exporter(registrationID: id, receive: receive)
        return id
    }

    /// An old runtime's cleanup cannot disconnect its replacement.
    public func unregisterExporter(registrationID: UUID) {
        guard exporter?.registrationID == registrationID else { return }
        exporter = nil
    }

    /// Updates plugin exclusions without changing the registered receiver.
    public func updatePolicy(_ policy: NectoEventCollectionPolicy) {
        self.policy = policy
    }

    public func record(
        _ input: NectoEvent.Input,
        source: NectoEvent.Source,
        channel: NectoInvocationChannel? = nil
    ) {
        let event = NectoEvent(
            eventID: UUID(), occurredAt: now(), installationID: installationID,
            nectoVersion: nectoVersion, source: source, channel: channel, input: input
        )
        guard let exporter,
              policy.allowsCollection(from: source.collectionPluginID)
        else { return }
        exporter.receive(event)
    }
}
