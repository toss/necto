// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import android.app.Application
import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.byteArrayPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import im.toss.necto.android.NectoAndroid
import im.toss.necto.android.NectoAndroidPlugins
import im.toss.necto.android.NectoDataStorePreferencesPlugin
import im.toss.necto.okhttp.NectoOkHttpInterceptor
import im.toss.necto.plugins.NectoNetworkPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import java.io.File

/** DataStore allows one instance per file, so the app owns it and hands it to Necto by name. */
val Context.settings by preferencesDataStore("settings")

/** Verifies SDK connection and plugin behaviour on a device or an emulator. */
class SampleApp : Application() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The client the Network tab sends through. Captured only in debug builds. */
    lateinit var client: OkHttpClient
        private set

    override fun onCreate() {
        super.onCreate()
        // Serves the Network tab's sample requests without internet access.
        LocalApi.start()

        val builder = OkHttpClient.Builder()
        if (BuildConfig.DEBUG) {
            // This app happens to use OkHttp, so it hands the plugin to the ready-made
            // interceptor. An app with its own stack registers `NectoNetworkPlugin()` all
            // the same and calls `report(...)` from wherever it already knows about a request.
            val network = NectoNetworkPlugin()
            builder.addInterceptor(NectoOkHttpInterceptor(network))

            // Preferences, files and UI Control need nothing reported: they read what is
            // already there. The seeds give the first two panels something real to show on
            // a fresh install.
            seedPreferences()
            seedFiles()

            NectoAndroid.start(
                this,
                listOf(
                    network,
                    // The other direction: a capability the Mac can call into rather than
                    // one that only pushes.
                    ExampleContractPlugin(this),
                    // Two more of the shipped plugins, registered the same way and just as
                    // optional. An app that wants neither simply leaves them out.
                    ExampleTelemetry.events,
                    ExampleTelemetry.performance(this),
                    NectoDataStorePreferencesPlugin(mapOf("settings" to settings)),
                    NectoAndroidPlugins.files(this),
                    NectoAndroidPlugins.control(this),
                ),
            )
            ExampleTelemetry.start()
        }
        client = builder.build()
    }

    /** A few files of each shape a real app keeps, written once. */
    private fun seedFiles() {
        val documents = filesDir
        val receipts = File(documents, "receipts")
        if (receipts.exists()) return

        receipts.mkdirs()
        File(receipts, "2026-07-29.json").writeText(
            """
            {
              "id": "rcpt_9f8e7d",
              "total": 24900,
              "currency": "KRW"
            }
            """.trimIndent() + "\n",
        )
        File(documents, "notes.txt").writeText("Notes the app wrote for itself.\n")
        File(documents, "cache.bin").writeBytes(ByteArray(512) { (it % 251).toByte() })
    }

    /**
     * One key of each shape DataStore stores, plus a counter that actually counts.
     * Asynchronous because DataStore is; the panel reads it well after this lands.
     */
    private fun seedPreferences() {
        scope.launch {
            settings.edit { preferences ->
                preferences[LAUNCH_COUNT] = (preferences[LAUNCH_COUNT] ?: 0) + 1
                // DataStore has no date type: apps keep a timestamp as epoch milliseconds.
                preferences[LAST_LAUNCH] = System.currentTimeMillis()
                if (preferences[THEME] == null) {
                    preferences[THEME] = "system"
                    preferences[ONBOARDING_SEEN] = true
                    preferences[INTERESTS] = setOf("kotlin", "debugging")
                    preferences[PLAYBACK_RATE] = 1.25
                    preferences[FONT_SCALE] = 1.1f
                    // Read-only in the panel: there is no sensible way to edit raw bytes there.
                    preferences[PUSH_TOKEN] = ByteArray(64) { it.toByte() }
                }
            }
        }
    }

    private companion object {
        val LAUNCH_COUNT = intPreferencesKey("example.launchCount")
        val LAST_LAUNCH = longPreferencesKey("example.lastLaunch")
        val THEME = stringPreferencesKey("example.theme")
        val ONBOARDING_SEEN = booleanPreferencesKey("example.onboarding.seen")
        val INTERESTS = stringSetPreferencesKey("example.interests")
        val PLAYBACK_RATE = doublePreferencesKey("example.playbackRate")
        val FONT_SCALE = floatPreferencesKey("example.fontScale")
        val PUSH_TOKEN = byteArrayPreferencesKey("example.pushToken")
    }
}
