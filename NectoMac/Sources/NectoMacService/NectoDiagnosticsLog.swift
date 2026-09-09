//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// Necto's own log: what it did, and what it could not do.
///
/// A debugging tool that fails silently is the worst kind. Until now a plugin that
/// would not load said so in Settings, and everything about the connection said
/// nothing at all — an app that never appears looked exactly like an app nobody
/// launched.
public actor NectoDiagnosticsLog {
    /// Counted rather than measured in bytes, unlike `NectoChannelBuffer`. A log line is
    /// a sentence Necto wrote about itself, so its size is bounded by construction; a
    /// channel payload is whatever the app under test sent.
    public static let capacity = 500

    public enum Severity: String, Sendable, CaseIterable {
        case info
        case warning
        /// Something a person has to know about. Only this raises the alert.
        case failure
    }

    public enum Source: String, Sendable, CaseIterable {
        case connection
        case plugin
        case bridge
        case target
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let at: Date
        public let severity: Severity
        public let source: Source
        public let message: String
        /// The part worth reading only once the line has been picked out.
        public let detail: String?

        public init(
            id: UUID = UUID(),
            at: Date = Date(),
            severity: Severity,
            source: Source,
            message: String,
            detail: String? = nil
        ) {
            self.id = id
            self.at = at
            self.severity = severity
            self.source = source
            self.message = message
            self.detail = detail
        }
    }

    private var entries: [Entry] = []
    private var droppedCount = 0
    private var acknowledgedFailures = 0

    public init() {}

    public func append(
        _ severity: Severity,
        _ source: Source,
        _ message: String,
        detail: String? = nil
    ) {
        entries.append(Entry(severity: severity, source: source, message: message, detail: detail))

        if entries.count > Self.capacity {
            let removed = entries.prefix(entries.count - Self.capacity)
            // An acknowledged failure that falls off the end must not come back as
            // unacknowledged when the count is recomputed.
            acknowledgedFailures -= removed.filter { $0.severity == .failure }.count
            acknowledgedFailures = max(0, acknowledgedFailures)
            droppedCount += removed.count
            entries.removeFirst(removed.count)
        }
    }

    /// Newest first: a log is read from the top when something has just gone wrong.
    public func recent(source: Source? = nil, severity: Severity? = nil) -> [Entry] {
        entries
            .filter { source == nil || $0.source == source }
            .filter { severity == nil || $0.severity == severity }
            .reversed()
    }

    public func dropped() -> Int {
        droppedCount
    }

    /// What the badge counts. Warnings are not included: an app disconnecting is
    /// ordinary, and a badge that lights up for ordinary things stops being read.
    public func unreadIssueCount() -> Int {
        max(0, entries.count { $0.severity == .failure } - acknowledgedFailures)
    }

    /// Called when the log has been looked at, not when it has been fixed.
    public func acknowledge() {
        acknowledgedFailures = entries.count { $0.severity == .failure }
    }

    /// The whole log as text, for pasting into a bug report.
    ///
    /// Timestamped in full, unlike the screen: a line read days later and somewhere
    /// else needs more than "15:39". Oldest first, because that is the order the
    /// events happened in and the order someone reading the report will follow.
    public func transcript() -> String {
        let stamp = ISO8601DateFormatter()
        var lines = entries.map { entry -> String in
            let head = [
                stamp.string(from: entry.at),
                entry.severity.rawValue,
                entry.source.rawValue,
                entry.message,
            ].joined(separator: "  ")

            guard let detail = entry.detail else { return head }
            return head + "\n    " + detail
        }

        // Said first, so a transcript that is missing its beginning says so.
        if droppedCount > 0 {
            lines.insert("\(droppedCount) earlier lines dropped.", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    public func clear() {
        entries.removeAll()
        droppedCount = 0
        acknowledgedFailures = 0
    }
}
