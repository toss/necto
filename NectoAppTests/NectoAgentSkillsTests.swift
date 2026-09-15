//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@Suite("Agent skill settings")
@MainActor
struct NectoAgentSkillsTests {
    @Test("Configuration folders control visibility and content changes offer updates")
    func detectAgentsAndUpdates() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: "necto-agent-skills-\(UUID())")
        defer { try? files.removeItem(at: root) }
        let home = root.appending(path: "home")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        let tool = root.appending(path: "Necto.app/Contents/MacOS/necto-cli")
        let bundle = root.appending(path: "Necto.app/Contents/Resources/NectoMac_necto-cli.bundle/Contents")
        let bundledSkill = bundle.appending(path: "Resources/Skills/necto/SKILL.md")
        try files.createDirectory(at: bundledSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.necto.skills", "CFBundlePackageType": "BNDL"],
            format: .xml, options: 0
        )
        try info.write(to: bundle.appending(path: "Info.plist"))
        try Data("current skill".utf8).write(to: bundledSkill)
        let skills = NectoAgentSkills(tool: tool, home: home)
        #expect(skills.agents.isEmpty)

        try files.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: false)
        try Data().write(to: home.appending(path: ".claude"))
        skills.refresh()
        #expect(skills.agents == [.codex])
        #expect(skills.installed.isEmpty)

        let installedSkill = home.appending(path: ".agents/skills/necto/SKILL.md")
        try files.createDirectory(at: installedSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old skill".utf8).write(to: installedSkill)
        skills.refresh()
        #expect(skills.installed == [.codex])
        #expect(skills.updates == [.codex])

        try Data("current skill".utf8).write(to: installedSkill)
        skills.refresh()
        #expect(skills.installed == [.codex])
        #expect(skills.updates.isEmpty)
    }

    @Test("Failed installation remains retryable and reports an error")
    func failedInstallation() async throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appending(path: "necto-agent-skills-\(UUID())")
        defer { try? files.removeItem(at: home) }
        try files.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        let skills = NectoAgentSkills(tool: URL(filePath: "/usr/bin/false"), home: home)
        await skills.install(.claude)
        #expect(skills.installing == nil)
        #expect(skills.installed.isEmpty)
        #expect(skills.error?.isEmpty == false)
    }
}
