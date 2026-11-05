//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoMacService
import Foundation

struct NectoInstalledPlugin: Identifiable, Sendable {
    typealias Source = NectoInstalledPackage.Source

    let package: NectoInstalledPackage

    init(package: NectoInstalledPackage) {
        self.package = package
    }

    init(
        manifest: NectoPluginManifest,
        rootURL: URL,
        source: Source,
        archive: NectoPanelArchive,
        contentIdentity: String,
        installation: NectoLocalPluginInstallation? = nil
    ) {
        self.init(package: NectoInstalledPackage(
            manifest: manifest, rootURL: rootURL, source: source, archive: archive,
            contentIdentity: contentIdentity, installation: installation
        ))
    }

    var id: String { package.id }
    var manifest: NectoPluginManifest { package.manifest }
    var rootURL: URL { package.rootURL }
    var source: Source { package.source }
    var archive: NectoPanelArchive { package.archive }
    var contentIdentity: String { package.contentIdentity }
    var installation: NectoLocalPluginInstallation? { package.installation }
    var principal: NectoPluginPrincipal? { package.principal }

    var runsInBackground: Bool {
        source == .installed && !manifest.requiresTarget
            && manifest.operations.contains { NectoBackgroundProvider().descriptor.mismatch(with: $0) == nil }
    }
}
