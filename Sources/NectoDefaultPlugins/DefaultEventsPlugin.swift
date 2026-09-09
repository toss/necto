//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoSDK
import Foundation

/// Somewhere to record what the app did.
///
/// A capture mechanism talks to this rather than to `DefaultEventsPlugin`, so an app
/// that already has a logger of its own routes it here without depending on the
/// shipped plugin, and a test can stand in for the whole thing.
public protocol NectoEventReporting: AnyObject, Sendable {
    func report(_ event: NectoEvent)
}

/// One thing the app did, at one moment.
///
/// Deliberately small. An event log is read by scanning down a column, so anything
/// that cannot be scanned belongs in the message rather than in another field.
public struct NectoEvent: Sendable, Hashable, Identifiable {
    public enum Level: String, Sendable, CaseIterable {
        case debug
        case info
        case warn
        case error
    }

    public let id: String
    public let at: Date
    public let level: Level
    /// What part of the app this came from: `Router`, `Auth`, `Cache`.
    public let tag: String
    public let message: String
    /// Anything worth reading once the line has been picked out.
    public let detail: [String: String]

    public init(
        id: String = UUID().uuidString,
        at: Date = Date(),
        level: Level,
        tag: String,
        message: String,
        detail: [String: String] = [:]
    ) {
        self.id = id
        self.at = at
        self.level = level
        self.tag = tag
        self.message = message
        self.detail = detail
    }
}

/// The app's own log, read from Necto.
///
/// Shipped with Necto and optional like anything else: link it, register it, and hand
/// it events from wherever the app already knows about them.
///
/// ```swift
/// let events = DefaultEventsPlugin()
/// NectoSDK.register(events)
///
/// events.report(NectoEvent(level: .warn, tag: "Cache", message: "Evicted 240 entries"))
/// ```
public final class DefaultEventsPlugin: NectoPluginable, NectoEventReporting, @unchecked Sendable {
    /// Keeps memory bounded on a long session. Older events fall off the end.
    public static let capacity = 5000

    public let id = "event-log"

    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module, subdirectory: "Panels/event-log") }


    private let lock = NSLock()
    private var events: [NectoEvent] = []
    private var listeners: [UUID: NectoHandler.Out] = [:]

    public init() {}

    public func register(_ necto: NectoHandler) {
        necto.handle("events.list") { [self] input in
            let limit = Int(input["limit"]?.numberValue ?? 500)
            let wanted = input["level"]?.stringValue.flatMap(NectoEvent.Level.init(rawValue:))

            let page = lock.withLock {
                events
                    .filter { wanted == nil || $0.level == wanted }
                    .prefix(limit)
            }
            return ["events": .array(page.map(Self.summary))]
        }

        necto.handle("events.detail") { [self] input in
            guard let eventID = input["eventID"]?.stringValue else {
                throw NectoBridgeError(code: .invalidInput, message: "eventID is required")
            }
            guard let event = lock.withLock({ events.first { $0.id == eventID } }) else {
                throw NectoBridgeError(code: .operationUnavailable, message: "No event '\(eventID)'")
            }
            return ["event": Self.detail(event)]
        }

        necto.handle("events.observe") { [self] _, out in
            let token = UUID()
            lock.withLock { listeners[token] = out }
            defer { lock.withLock { _ = listeners.removeValue(forKey: token) } }

            // Held open until the caller stops listening; `report` does the sending.
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(60))
            }
        }

        necto.handle("events.clear") { [self] _ in
            lock.withLock { events.removeAll() }
            return ["cleared": .bool(true)]
        }
    }

    /// Records one event. Safe to call from any thread, and whether or not a host is
    /// attached: the app keeps its own log, so it collects from the moment it starts
    /// rather than from the moment someone opens the panel.
    public func report(_ event: NectoEvent) {
        let out = lock.withLock { () -> [NectoHandler.Out] in
            events.insert(event, at: 0)
            if events.count > Self.capacity {
                events.removeLast(events.count - Self.capacity)
            }
            return Array(listeners.values)
        }

        let payload: NectoJSONValue = ["event": Self.summary(event)]
        for listener in out {
            Task { await listener.send(payload) }
        }
    }

    // MARK: Coding

    /// What a row needs. `detail` is deliberately absent: a list of five thousand
    /// events should not carry five thousand dictionaries with it.
    static func summary(_ event: NectoEvent) -> NectoJSONValue {
        [
            "id": .string(event.id),
            "at": .number(event.at.timeIntervalSince1970 * 1000),
            "level": .string(event.level.rawValue),
            "tag": .string(event.tag),
            "message": .string(event.message),
            "hasDetail": .bool(!event.detail.isEmpty),
        ]
    }

    static func detail(_ event: NectoEvent) -> NectoJSONValue {
        guard case var .object(fields) = summary(event) else { return summary(event) }
        fields["detail"] = .object(event.detail.mapValues(NectoJSONValue.string))
        return .object(fields)
    }
}
