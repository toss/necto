//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoMacService
import NectoModel
import Foundation

struct NectoShellCaller: Identifiable, Hashable {
    enum Kind: Hashable {
        case device
        case desktop
        case cli
    }

    let principal: NectoPluginPrincipal
    let name: String
    let version: String?
    let author: String?
    let systemImage: String
    let kind: Kind

    var id: String { "\(principal.pluginID)\u{1F}\(principal.sourceIdentity)" }
}

extension NectoAppModel {
    var shellCallers: [NectoShellCaller] {
        var seen: Set<NectoPluginPrincipal> = []

        let device = devicePlugins.compactMap { discovered -> NectoShellCaller? in
            let plugin = discovered.plugin
            guard plugin.manifest.usesShellBridge else { return nil }
            let principal = NectoPluginPrincipal(
                pluginID: plugin.id,
                sourceIdentity: "device:\(discovered.target.appBundleID)"
            )
            guard seen.insert(principal).inserted else { return nil }
            return NectoShellCaller(
                principal: principal,
                name: plugin.manifest.name,
                version: plugin.manifest.version,
                author: plugin.manifest.author,
                systemImage: plugin.manifest.icon.systemName,
                kind: .device
            )
        }

        let desktop = plugins.compactMap { plugin -> NectoShellCaller? in
            guard plugin.manifest.usesShellBridge else { return nil }
            guard let principal = plugin.principal else { return nil }
            guard seen.insert(principal).inserted else { return nil }
            return NectoShellCaller(
                principal: principal,
                name: plugin.manifest.name,
                version: plugin.manifest.version,
                author: plugin.manifest.author,
                systemImage: plugin.manifest.icon.systemName,
                kind: .desktop
            )
        }

        let cli = NectoShellCaller(
            principal: NectoShellIdentity.cli,
            name: "necto-cli",
            version: nil,
            author: nil,
            systemImage: "terminal",
            kind: .cli
        )
        return device.sorted { $0.name < $1.name }
            + desktop.sorted { $0.name < $1.name }
            + [cli]
    }

    func shellCallerName(for principal: NectoPluginPrincipal) -> String {
        shellCallers.first { $0.principal == principal }?.name ?? principal.pluginID
    }

    func shellCallerSource(for principal: NectoPluginPrincipal) -> String {
        if principal == NectoShellIdentity.cli { return "necto-cli" }
        if let plugin = plugins.first(where: { $0.principal == principal }),
           let installation = plugin.installation {
            return installation.origin?.label ?? installation.directoryPath
        }
        if let discovered = devicePlugins.first(where: { $0.plugin.principal == principal }),
           case let .device(appName, appBundleID) = discovered.plugin.source {
            return "\(appName) (\(appBundleID))"
        }
        return principal.sourceIdentity
    }
}

private extension NectoPluginManifest {
    var usesShellBridge: Bool {
        operations.contains {
            $0.binding.name == NectoShellExecuteProvider.key
                || $0.binding.name == NectoShellAuthorizationProvider.key
        }
    }
}
