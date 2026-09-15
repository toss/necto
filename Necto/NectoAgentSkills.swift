//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService
import Observation

@MainActor
@Observable
final class NectoAgentSkills {
    enum Agent: String, CaseIterable, Identifiable {
        case codex, claude

        var id: Self { self }
        var name: String { self == .codex ? "Codex" : "Claude Code" }
        var configurationDirectory: String { self == .codex ? ".codex" : ".claude" }
        var skillPath: String {
            self == .codex ? ".agents/skills/necto/SKILL.md" : ".claude/skills/necto/SKILL.md"
        }
    }

    private(set) var agents: [Agent] = []
    private(set) var installed: Set<Agent> = []
    private(set) var updates: Set<Agent> = []
    private(set) var installing: Agent?
    private(set) var error: String?

    @ObservationIgnored private let tool: URL
    @ObservationIgnored private let home: URL

    init(
        tool: URL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/necto-cli"),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.tool = tool
        self.home = home
        refresh()
    }

    func refresh() {
        guard installing == nil else { return }
        agents = Agent.allCases.filter { agent in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: home.appending(path: agent.configurationDirectory).path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
        installed = Set(agents.filter {
            (try? FileManager.default.attributesOfItem(atPath: home.appending(path: $0.skillPath).path)[.type]
                as? FileAttributeType) == .typeRegular
        })
        if let content = bundledContent {
            updates = Set(installed.filter { (try? Data(contentsOf: home.appending(path: $0.skillPath))) != content })
        } else {
            updates = []
        }
    }

    func install(_ agent: Agent) async {
        guard installing == nil, agents.contains(agent),
              !installed.contains(agent) || updates.contains(agent) else { return }
        installing = agent
        error = nil
        defer {
            installing = nil
            refresh()
        }
        do {
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["CFFIXED_USER_HOME"] = home.path
            var arguments = ["skills", "install", "--\(agent.rawValue)"]
            if updates.contains(agent) { arguments.append("--force") }
            let output = try await NectoProcessRunner.run(tool.path, arguments: arguments, environment: environment)
            guard output.exitCode == 0 else {
                let detail = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                error = detail.isEmpty ? NectoL10n.text("Could not install the skill.") : detail
                return
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var bundledContent: Data? {
        let resources = tool.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        guard let bundle = Bundle(url: resources.appending(path: "NectoMac_necto-cli.bundle")),
              let url = bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/necto") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
