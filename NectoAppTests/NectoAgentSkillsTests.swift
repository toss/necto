//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@Suite("Agent skill settings")
@MainActor
struct NectoAgentSkillsTests {
    @Test("Configuration folders control visibility, and stale skills install as updates")
    func installAndUpdate() async throws {
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
        try files.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            skill="${0%/*}/../../../home/.agents/skills/necto/SKILL.md"
            /bin/mkdir -p "${skill%/*}" && printf '%s' 'current skill' > "$skill"
            """
        try Data(script.utf8).write(to: tool)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let skills = NectoAgentSkills(tool: tool, home: home)
        #expect(skills.agents.isEmpty)
        #expect(await skills.install(.codex) == nil)

        try files.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: false)
        try Data().write(to: home.appending(path: ".claude"))
        skills.refresh()
        #expect(skills.agents == [.codex])
        #expect(skills.installed.isEmpty)

        let install = await skills.install(.codex)
        #expect(install?.isUpdate == false)
        #expect(install?.succeeded == true)
        #expect(skills.installed == [.codex])
        #expect(skills.updates.isEmpty)
        #expect(await skills.install(.codex) == nil)

        let installedSkill = home.appending(path: ".agents/skills/necto/SKILL.md")
        try Data("old skill".utf8).write(to: installedSkill)
        skills.refresh()
        #expect(skills.installed == [.codex])
        #expect(skills.updates == [.codex])

        let update = await skills.install(.codex)
        #expect(update?.isUpdate == true)
        #expect(update?.succeeded == true)
        #expect(skills.installed == [.codex])
        #expect(skills.updates.isEmpty)
    }

    @Test("A nonzero exit or failed launch leaves installation retryable", arguments: [false, true])
    func failedInstallation(toolExists: Bool) async throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appending(path: "necto-agent-skills-\(UUID())")
        defer { try? files.removeItem(at: home) }
        try files.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        let tool = toolExists ? URL(filePath: "/usr/bin/false") : home.appending(path: "missing-necto-cli")
        let skills = NectoAgentSkills(tool: tool, home: home)
        let install = await skills.install(.claude)
        #expect(install?.isUpdate == false)
        #expect(install?.succeeded == false)
        #expect(skills.installing == nil)
        #expect(skills.installed.isEmpty)
        #expect(skills.error?.isEmpty == false)
    }
}
