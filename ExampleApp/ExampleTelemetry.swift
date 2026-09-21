//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoDefaultPlugins
import NectoProcessMetrics
import Foundation

/// Gives the Events and Performance plugins something real to show.
///
/// The app explicitly opts into Necto's process sampler.
enum ExampleTelemetry {
    static let events = NectoEventsPlugin()
    static let performance = ProcessPerformancePlugin()

    static func start() {
        events.report(NectoEvent(level: .info, tag: "Boot", message: "Necto Example started"))

    }

    /// Called from wherever the app already knows something happened.
    static func log(_ level: NectoEvent.Level, _ tag: String, _ message: String, detail: [String: String] = [:]) {
        events.report(NectoEvent(level: level, tag: tag, message: message, detail: detail))
    }
}
