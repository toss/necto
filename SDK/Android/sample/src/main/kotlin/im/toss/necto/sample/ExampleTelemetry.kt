// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import android.content.Context
import im.toss.necto.android.NectoAndroidPlugins
import im.toss.necto.plugins.NectoEvent
import im.toss.necto.plugins.NectoEventsPlugin
import im.toss.necto.plugins.NectoPerformancePlugin

/**
 * Gives the Events and Performance plugins something real to show.
 *
 * The app explicitly opts into Necto's process sampler.
 */
object ExampleTelemetry {
    val events = NectoEventsPlugin()

    /** The sampler reads this process through a Context, so it is made once the app has one. */
    fun performance(context: Context): NectoPerformancePlugin = NectoAndroidPlugins.performance(context)

    fun start() {
        events.report(NectoEvent(NectoEvent.Level.INFO, "Boot", "Necto Example started"))
    }

    /** Called from wherever the app already knows something happened. */
    fun log(level: NectoEvent.Level, tag: String, message: String, detail: Map<String, String> = emptyMap()) {
        events.report(NectoEvent(level, tag, message, detail))
    }
}
