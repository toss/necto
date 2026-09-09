//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing

@testable import NectoMacService

@Suite("Local plugin identity")
struct NectoLocalPluginInstallationTests {
    @Test func approvedUpdateKeepsIdentityAndGrants() async throws {
        var record = NectoLocalPluginInstallation(pluginID: "com.example.notes", directoryPath: "/plugins/notes", approvedContentHash: "v1")
        let principal = record.principal
        let policy = NectoShellPolicy()
        try await policy.approve("echo necto", for: principal)
        record.approveUpdate(contentHash: "v2", origin: nil)
        #expect(record.principal == principal)
        #expect(record.approvedContentHash == "v2")
        #expect(await policy.allows("echo necto", for: record.principal))
        let restored = try JSONDecoder().decode(NectoLocalPluginInstallation.self, from: JSONEncoder().encode(record))
        #expect(restored == record)
    }

    @Test func reinstallDoesNotInheritAnIdenticalIDsPermissions() async {
        let first = NectoLocalPluginInstallation(pluginID: "notes", directoryPath: "/plugins/notes", approvedContentHash: "same")
        let next = NectoLocalPluginInstallation(pluginID: "notes", directoryPath: "/plugins/notes", approvedContentHash: "same")
        let policy = NectoShellPolicy()
        await policy.setAccessLevel(.fullAccess, for: first.principal)
        #expect(first.principal != next.principal)
        #expect(await policy.allows("anything", for: next.principal) == false)
        #expect(!first.matches(pluginID: "other", directoryPath: first.directoryPath))
        #expect(!first.matches(pluginID: first.pluginID, directoryPath: "/elsewhere"))
    }

    @Test func replacementUsesApprovedBytesAndRejectsConcurrentChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "necto-install-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "notes")
        let first = NectoPanelArchive(files: [.init(path: "index.html", data: Data("first".utf8))])
        let second = NectoPanelArchive(files: [.init(path: "index.html", data: Data("second".utf8))])
        try NectoLocalPluginFiles.install(first, at: destination, replacingContentHash: nil)
        #expect(throws: (any Error).self) {
            try NectoLocalPluginFiles.install(second, at: destination, replacingContentHash: "unreviewed")
        }
        #expect(try NectoPanelArchive.read(directory: destination) == first)
        #expect(throws: (any Error).self) {
            try NectoLocalPluginFiles.install(second, at: destination, replacingContentHash: nil)
        }
        #expect(try NectoPanelArchive.read(directory: destination) == first)
        try NectoLocalPluginFiles.install(second, at: destination, replacingContentHash: first.contentHash)
        #expect(try NectoPanelArchive.read(directory: destination) == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notes"])
    }
}
