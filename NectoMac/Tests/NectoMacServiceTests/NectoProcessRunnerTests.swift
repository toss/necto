//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Darwin
import Foundation
import Testing
@testable import NectoMacService

@Suite("Async process I/O")
struct NectoProcessRunnerTests {
    @Test("omitted environment inherits the parent environment")
    func inheritedEnvironment() async throws {
        let home = try #require(ProcessInfo.processInfo.environment["HOME"])
        let output = try await NectoProcessRunner.run("/usr/bin/printenv", arguments: ["HOME"])
        #expect(output.exitCode == 0)
        #expect(output.stdout == Data("\(home)\n".utf8))
    }

    @Test("explicit environment replaces rather than merges the parent environment")
    func explicitEnvironment() async throws {
        let output = try await NectoProcessRunner.run(
            "/usr/bin/env", arguments: [], environment: ["NECTO_PROCESS_TEST": "provided"]
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout == Data("NECTO_PROCESS_TEST=provided\n".utf8))
    }

    @Test("explicit empty environment stays empty")
    func emptyEnvironment() async throws {
        let output = try await NectoProcessRunner.run("/usr/bin/env", arguments: [], environment: [:])
        #expect(output.exitCode == 0)
        #expect(output.stdout.isEmpty)
    }

    @Test("bounded standard input reaches the process through EOF")
    func standardInput() async throws {
        let input = Data(repeating: 97, count: NectoProcessRunner.maximumStandardInputBytes)
        let output = try await NectoProcessRunner.run("/bin/cat", arguments: [], standardInput: input)
        #expect(output.stdout == input)
        #expect(output.exitCode == 0)
    }

    @Test("oversized input is rejected without launching the process")
    func rejectsOversizedInput() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "necto-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: NectoProcessRunner.Failure.standardInputLimitExceeded) {
            try await NectoProcessRunner.run(
                "/usr/bin/touch", arguments: [file.path],
                standardInput: Data(repeating: 0, count: NectoProcessRunner.maximumStandardInputBytes + 1)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("drains both full pipes concurrently")
    func simultaneousOutput() async throws {
        let output = try await NectoProcessRunner.run(
            "/bin/bash", arguments: ["-c", "head -c 262144 /dev/zero & head -c 262144 /dev/zero >&2 & wait"],
            timeoutMilliseconds: 5_000
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout == Data(repeating: 0, count: 262_144))
        #expect(output.stderr == Data(repeating: 0, count: 262_144))
    }

    @Test("preserves separate output and nonzero status")
    func exitStatus() async throws {
        let output = try await NectoProcessRunner.run(
            "/bin/bash", arguments: ["-c", "printf out; printf err >&2; exit 7"]
        )
        #expect(output.exitCode == 7)
        #expect(output.stdout == Data("out".utf8))
        #expect(output.stderr == Data("err".utf8))
    }

    @Test("caps stdout and stderr together")
    func combinedOutputLimit() async {
        await #expect(throws: NectoProcessRunner.Failure.outputLimitExceeded) {
            try await NectoProcessRunner.run(
                "/bin/bash", arguments: ["-c", "printf 123456; printf 123456 >&2"], maximumOutputBytes: 10
            )
        }
    }

    @Test("deadline also bounds pipes inherited by a descendant")
    func orphanPipe() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: NectoProcessRunner.Failure.timedOut) {
            try await NectoProcessRunner.run(
                "/bin/bash", arguments: ["-c", "sleep 2 & exit 0"], timeoutMilliseconds: 100
            )
        }
        #expect(clock.now - start < .seconds(1))
    }

    @Test("kills a direct child that ignores termination")
    func ignoresTermination() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: NectoProcessRunner.Failure.timedOut) {
            try await NectoProcessRunner.run(
                "/bin/bash", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeoutMilliseconds: 100
            )
        }
        #expect(clock.now - start < .seconds(3))
    }

    @Test("cancellation waits for direct-child termination")
    func cancellation() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "necto-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let task = Task {
            try await NectoProcessRunner.run(
                "/bin/bash", arguments: ["-c", "printf '%s' $$ > \"$1\"; while :; do :; done", "necto-test", file.path]
            )
        }
        defer { task.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        var processID: Int32?
        while processID == nil, clock.now < deadline {
            processID = (try? String(contentsOf: file, encoding: .utf8)).flatMap(Int32.init)
            if processID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(processID)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test("pre-cancelled calls do not launch a child")
    func cancelledBeforeStart() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "necto-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NectoProcessRunner.run("/usr/bin/touch", arguments: [file.path])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("launch failures finish without waiting for a deadline")
    func launchFailure() async {
        await #expect(throws: (any Error).self) {
            try await NectoProcessRunner.run("/necto-nonexistent-executable", arguments: [])
        }
    }
}
