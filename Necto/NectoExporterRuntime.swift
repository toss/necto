//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoMacService

/// The exporter document lives independently of feature panels and their windows.
@MainActor
final class NectoExporterRuntime {
    private var identity: String?
    private(set) var page: NectoWebPage?

    func synchronize(
        exporter: NectoInstalledExporter?,
        registry: NectoPluginRegistry,
        eventDispatcher: NectoEventDispatcher,
        diagnostics: NectoDiagnosticsLog
    ) {
        let nextIdentity = exporter.map {
            "\($0.id)|\($0.principal?.sourceIdentity ?? "")|\($0.contentIdentity)"
        }
        guard identity != nextIdentity else { return }
        page?.invalidate()
        page = nil
        identity = nextIdentity
        guard let exporter else { return }
        let page = NectoWebPage(
            package: exporter.package,
            registry: registry,
            target: nil,
            locale: NectoL10n.languageCode,
            eventDispatcher: eventDispatcher,
            diagnostics: diagnostics
        )
        page.setVisible(false, find: nil, scale: 1)
        self.page = page
    }
}
