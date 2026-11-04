// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.consumer

import android.app.Application
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import im.toss.necto.android.NectoAndroidControlPlugin
import im.toss.necto.android.NectoDataStorePreferencesPlugin
import im.toss.necto.android.NectoProcessMetricPlugin
import im.toss.necto.okhttp.OkHttpNetworkPlugin
import im.toss.necto.plugins.NectoEventsPlugin
import im.toss.necto.plugins.NectoFilesPlugin
import im.toss.necto.sdk.NectoPlugin
import java.io.File

fun selectedPlugins(app: Application): List<NectoPlugin> = listOf(
    NectoEventsPlugin(),
    OkHttpNetworkPlugin(),
    NectoFilesPlugin(app),
    NectoProcessMetricPlugin(app),
    NectoAndroidControlPlugin(app),
    NectoDataStorePreferencesPlugin(mapOf(
        "settings" to PreferenceDataStoreFactory.create { File(app.filesDir, "settings.preferences_pb") },
    )),
)
