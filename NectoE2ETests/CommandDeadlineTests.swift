//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@Suite("E2E command deadlines", .serialized)
@MainActor
struct CommandDeadlineTests {
    @Test("successful commands may write diagnostics to stderr")
    func successfulCommandWithStderr() throws {
        let result = AppFixture.Result(status: 0, output: "ok", error: "warning")
        try result.requireSuccess()
        #expect(result.error == "warning")
    }

    @Test("an exhausted preparation budget does not launch the next command")
    func expiredBeforeLaunch() async throws {
        let app = try AppFixture()
        let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        do {
            _ = try await app.run("/usr/bin/touch", [marker.path], deadline: .now - .seconds(1))
            Issue.record("An expired deadline must prevent command launch.")
        } catch {
            #expect(String(describing: error).contains("Command deadline expired before launch"))
        }
        await app.close()
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("an exhausted deadline stops a running command and preserves its output")
    func expiresWhileRunning() async throws {
        let app = try AppFixture()
        do {
            let command = try app.launch(URL(filePath: "/bin/sh"), ["-c", "echo command-started; exec /bin/sleep 60"])
            try await app.waitForOutput(command)
            do {
                _ = try await app.finish(command, deadline: .now - .seconds(1))
                Issue.record("A running command must stop at its deadline.")
            } catch {
                let message = String(describing: error)
                #expect(message.contains("Command timed out"))
                #expect(message.contains("command-started"))
            }
            let result = try await app.finish(command)
            #expect(result.status != 0)
        } catch {
            await app.close()
            throw error
        }
        await app.close()
    }
}
