//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoNetworkPlugin

@Suite("Network record coding")
struct NectoNetworkRecordCodingTests {
    private func curl(_ record: NectoNetworkRecord) throws -> String {
        try #require(NectoNetworkRecordCoding.detail(record)["curl"]?.stringValue)
    }

    @Test("writes a plain request as a plain command")
    func writesPlainCommand() throws {
        let record = NectoNetworkRecord(
            id: "1",
            method: "GET",
            url: "https://api.example.com/items?page=2",
            startedAtMilliseconds: 0,
            state: .completed,
            requestHeaders: ["Accept": "application/json"]
        )

        #expect(try curl(record) == """
        curl -X GET \\
          'https://api.example.com/items?page=2' \\
          -H 'Accept: application/json'
        """)
    }

    #if os(macOS)
    /// The command is there to be pasted into a terminal, and everything in it came
    /// from the app and the servers it talks to. Whatever a URL, a method or a header
    /// holds, a shell has to read it back as that one argument and nothing more.
    @Test("writes a command a shell reads back as the same request")
    func survivesAShell() throws {
        let record = NectoNetworkRecord(
            id: "1",
            method: "PO ST;id",
            url: "https://api.example.com/search?q=it's&next='; touch necto-was-here; '",
            startedAtMilliseconds: 0,
            state: .completed,
            requestHeaders: ["X-Na'me": "va'lue $(id) `id`"],
            requestBody: NectoNetworkRecord.Body(
                data: Data(#"{"note":"it's\nfine"}"#.utf8),
                contentType: "application/json"
            )
        )

        // Hands the arguments to `printf` instead of `curl`, one per NUL.
        let command = try curl(record).replacingOccurrences(of: "curl ", with: #"printf '%s\0' "#, options: .anchored)
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        shell.currentDirectoryURL = FileManager.default.temporaryDirectory
        shell.standardOutput = output
        try shell.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()

        let arguments = printed.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(shell.terminationStatus == 0)
        #expect(arguments == [
            "-X", "PO ST;id",
            "https://api.example.com/search?q=it's&next='; touch necto-was-here; '",
            "-H", "X-Na'me: va'lue $(id) `id`",
            "--data-raw", #"{"note":"it's\nfine"}"#,
        ])
    }
    #endif
}
