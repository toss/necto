// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.consumer

import android.app.Application
import im.toss.necto.sdk.NectoPlugin
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import im.toss.necto.android.NectoDataStorePreferencesPlugin
import java.io.File

fun selectedPlugins(app: Application): List<NectoPlugin> = listOf(NectoDataStorePreferencesPlugin(mapOf(
    "settings" to PreferenceDataStoreFactory.create { File(app.filesDir, "settings.preferences_pb") },
)))
