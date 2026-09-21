//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoDefaultPlugins
import NectoModel
import NectoProcessMetrics
import NectoSDK
import NectoURLSessionCapture
import Testing

#if canImport(NectoMacService) || canImport(NectoCLIService) || canImport(ArgumentParser)
#error("The SDK consumer must not depend on host modules")
#endif

@Test("One SDK product provides the defaults without registering or starting them")
func sdkConsumer() throws {
    #expect(NectoSDK.status == .stopped)
    #expect(NectoSDK.plugins.isEmpty)

    let events = NectoEventsPlugin()
    let performance = ProcessPerformancePlugin()
    let network = URLSessionNetworkPlugin()
    for plugin in [events as any NectoPluginable, performance, network] {
        let panel = try #require(plugin.panel)
        #expect(FileManager.default.fileExists(atPath: panel.root.appendingPathComponent("index.html").path))
    }
    #expect(NectoSDK.plugins.isEmpty)
    #expect(NectoSDK.status == .stopped)

    NectoSDK.register(events)
    defer { NectoSDK.unregister(id: events.id) }
    #expect(NectoSDK.plugins.map(\.id) == [events.id])
    #expect(NectoSDK.status == .stopped)
}
