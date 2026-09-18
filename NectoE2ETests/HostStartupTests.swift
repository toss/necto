//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@Suite("E2E host startup diagnostics", .serialized)
@MainActor
struct HostStartupTests {
    @Test("reports an exited host without waiting for the startup deadline")
    func exitedHost() async throws {
        let app = try AppFixture()
        do {
            let host = try app.launch(URL(filePath: "/bin/sh"), ["-c", "echo startup-failed >&2; exit 7"])
            _ = try await app.finish(host)
            do {
                try await app.waitForControlSocket(host)
                Issue.record("An exited host must fail startup.")
            } catch {
                let message = String(describing: error)
                #expect(message.contains("Necto exited before its control socket was ready (status 7)"))
                #expect(message.contains("startup-failed"))
                #expect(!message.contains("Timed out"))
            }
        } catch {
            await app.close()
            throw error
        }
        await app.close()
    }

    @Test("a startup timeout includes the host and failed CLI probe logs")
    func timeoutDiagnostics() async throws {
        let app = try AppFixture()
        do {
            let host = try app.launch(URL(filePath: "/bin/sleep"), ["60"])
            do {
                try await app.waitForControlSocket(host, timeout: .zero)
                Issue.record("A host without a control socket must time out.")
            } catch {
                let message = String(describing: error)
                #expect(message.contains("Timed out waiting for GUI control socket"))
                #expect(message.contains("Host logs:"))
                #expect(message.contains("0-sleep.stderr"))
                #expect(message.contains("Last command logs:"))
                #expect(message.contains("Could not reach Necto"))
            }
        } catch {
            await app.close()
            throw error
        }
        await app.close()
    }
}
