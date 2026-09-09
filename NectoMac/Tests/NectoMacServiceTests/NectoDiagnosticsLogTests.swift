//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoMacService

@Suite("Diagnostics log")
struct NectoDiagnosticsLogTests {
    @Test("reads newest first")
    func newestFirst() async {
        let log = NectoDiagnosticsLog()
        await log.append(.info, .connection, "first")
        await log.append(.info, .connection, "second")

        #expect(await log.recent().map(\.message) == ["second", "first"])
    }

    @Test("filters by source and by severity")
    func filters() async {
        let log = NectoDiagnosticsLog()
        await log.append(.info, .connection, "listening")
        await log.append(.failure, .plugin, "would not load")
        await log.append(.warning, .connection, "app went away")

        #expect(await log.recent(source: .plugin).map(\.message) == ["would not load"])
        #expect(await log.recent(severity: .failure).map(\.message) == ["would not load"])
        #expect(await log.recent(source: .connection).count == 2)
    }

    // MARK: What the badge counts

    /// The rule the badge lives by: an app disconnecting is ordinary and must not light
    /// it up, or it stops being read.
    @Test("counts only failures as issues")
    func onlyFailuresAreIssues() async {
        let log = NectoDiagnosticsLog()
        await log.append(.info, .target, "app connected")
        await log.append(.warning, .target, "app disconnected")

        #expect(await log.unreadIssueCount() == 0)

        await log.append(.failure, .connection, "handshake refused")
        #expect(await log.unreadIssueCount() == 1)
    }

    @Test("stops counting what has been looked at")
    func acknowledgeClears() async {
        let log = NectoDiagnosticsLog()
        await log.append(.failure, .connection, "handshake refused")
        await log.append(.failure, .plugin, "version mismatch")

        await log.acknowledge()
        #expect(await log.unreadIssueCount() == 0)

        await log.append(.failure, .bridge, "permission denied")
        #expect(await log.unreadIssueCount() == 1)
    }

    @Test("an acknowledged failure does not come back when it falls off the end")
    func acknowledgedFailuresDoNotReturn() async {
        let log = NectoDiagnosticsLog()
        await log.append(.failure, .connection, "old failure")
        await log.acknowledge()

        for index in 0 ..< NectoDiagnosticsLog.capacity {
            await log.append(.info, .connection, "line \(index)")
        }

        #expect(await log.unreadIssueCount() == 0)
    }

    // MARK: Staying bounded

    @Test("keeps the newest lines and says how many it lost")
    func evictsOldest() async {
        let log = NectoDiagnosticsLog()

        for index in 0 ..< (NectoDiagnosticsLog.capacity + 10) {
            await log.append(.info, .connection, "line \(index)")
        }

        let entries = await log.recent()
        #expect(entries.count == NectoDiagnosticsLog.capacity)
        #expect(entries.first?.message == "line \(NectoDiagnosticsLog.capacity + 9)")
        #expect(await log.dropped() == 10)
    }

    @Test("clearing resets the count and the badge")
    func clearResets() async {
        let log = NectoDiagnosticsLog()
        await log.append(.failure, .plugin, "would not load")

        await log.clear()

        #expect(await log.recent().isEmpty)
        #expect(await log.dropped() == 0)
        #expect(await log.unreadIssueCount() == 0)
    }

    // MARK: Pasting it somewhere else

    @Test("writes a transcript oldest first, one line per entry")
    func transcriptIsChronological() async {
        let log = NectoDiagnosticsLog()
        await log.append(.info, .connection, "started")
        await log.append(.warning, .target, "app disconnected")

        let lines = await log.transcript().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("info  connection  started"))
        #expect(lines[1].hasSuffix("warning  target  app disconnected"))
    }

    @Test("puts a detail on its own indented line")
    func transcriptIndentsDetail() async {
        let log = NectoDiagnosticsLog()
        await log.append(.failure, .plugin, "would not load", detail: "undeclared permission")

        let lines = await log.transcript().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[1] == "    undeclared permission")
    }

    /// A transcript missing its beginning has to say so, or it is read as the whole
    /// story of what happened.
    @Test("says up front when it is missing its beginning")
    func transcriptAdmitsWhatItLost() async {
        let log = NectoDiagnosticsLog()
        for index in 0 ..< (NectoDiagnosticsLog.capacity + 3) {
            await log.append(.info, .connection, "line \(index)")
        }

        let transcript = await log.transcript()
        #expect(transcript.hasPrefix("3 earlier lines dropped.\n"))
    }

    @Test("is empty when the log is")
    func transcriptOfNothing() async {
        let log = NectoDiagnosticsLog()
        #expect(await log.transcript().isEmpty)
    }

    @Test("carries a detail worth reading only once the line is picked out")
    func keepsDetail() async {
        let log = NectoDiagnosticsLog()
        await log.append(.failure, .plugin, "would not load", detail: "manifest names an undeclared permission")

        #expect(await log.recent().first?.detail == "manifest names an undeclared permission")
    }
}
