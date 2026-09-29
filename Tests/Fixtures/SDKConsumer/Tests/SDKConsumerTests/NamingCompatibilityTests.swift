//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import NectoSDK
import NectoURLSessionCapture
import Testing

// Keep this adopter on the old API to catch source compatibility regressions.
private struct LegacyPlugin: NectoPluginable {
    let id = "com.example.legacy"

    func register(_ necto: NectoHandler) {
        necto.handle("legacy.observe") { _, out in
            let legacyOut: NectoHandler.Out = out
            await legacyOut.send(.null)
        }
    }
}

@Test("Deprecated SDK names remain usable by an external consumer")
func namingCompatibility() throws {
    let plugin: any NectoPlugin = LegacyPlugin()
    #expect(plugin.id == "com.example.legacy")
    #expect(plugin.panel == nil)

    let legacy = NectoPluginCancel(requestID: "request-1")
    let current: NectoPluginCancellation = legacy
    let encoded = try JSONEncoder().encode(current)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
    #expect(object == ["requestID": "request-1"])
    #expect(try JSONDecoder().decode(NectoPluginCancel.self, from: encoded) == legacy)
    #expect(NectoEnvelope.Kind.pluginCancel.rawValue == "plugin.cancel")

    // Type-check both entry points without mutating process-wide URLProtocol state.
    let legacyRemove: () -> Void = NectoURLSessionCapture.remove
    let uninstall: () -> Void = NectoURLSessionCapture.uninstall
    _ = (legacyRemove, uninstall)
}
