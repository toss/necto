// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sample

import android.app.Application
import dev.necto.events.DefaultEventsPlugin
import dev.necto.sdk.NectoSDK

class SampleApplication : Application() {
    lateinit var events: DefaultEventsPlugin
        private set
    private lateinit var necto: NectoSDK

    override fun onCreate() {
        super.onCreate()
        events = DefaultEventsPlugin(this)
        necto = NectoSDK(this, listOf(events))
        necto.start()
        events.report("Android sample started", tag = "Lifecycle", detail = mapOf("package" to packageName))
    }
}
