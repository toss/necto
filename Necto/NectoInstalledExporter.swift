//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoMacService
import Foundation

struct NectoInstalledExporter: Identifiable, Sendable {
    let package: NectoInstalledPackage

    init(package: NectoInstalledPackage) {
        self.package = package
    }

    var id: String { package.id }
    var manifest: NectoPluginManifest { package.manifest }
    var rootURL: URL { package.rootURL }
    var source: NectoInstalledPackage.Source { package.source }
    var archive: NectoPanelArchive { package.archive }
    var contentIdentity: String { package.contentIdentity }
    var installation: NectoLocalPluginInstallation? { package.installation }
    var principal: NectoPluginPrincipal? { package.principal }
}
