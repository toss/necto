// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.app.Application
import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import im.toss.necto.plugins.NectoEventsPlugin
import im.toss.necto.plugins.NectoFilesPlugin
import im.toss.necto.plugins.NectoMetric
import im.toss.necto.plugins.NectoNetworkPlugin
import im.toss.necto.plugins.NectoPerformancePlugin
import im.toss.necto.plugins.NectoUIControlPlugin
import im.toss.necto.sdk.NectoPlugin

/** Factories for the plugins Necto ships, wired to Android. */
public object NectoAndroidPlugins {
    /**
     * Every shipped plugin: events, network, DataStore preferences, files, process
     * performance and UI Control. Pass in the [events] and [network] plugins the app
     * reports to, such as the one a `NectoOkHttpInterceptor` feeds, and the app's own
     * [dataStores] by name; the preferences plugin is left out when there are none.
     */
    public fun defaults(
        context: Context,
        events: NectoEventsPlugin = NectoEventsPlugin(),
        network: NectoNetworkPlugin = NectoNetworkPlugin(),
        dataStores: Map<String, DataStore<Preferences>> = emptyMap(),
    ): List<NectoPlugin> = listOfNotNull(
        events,
        network,
        dataStores.takeIf { it.isNotEmpty() }?.let(::NectoDataStorePreferencesPlugin),
        files(context),
        performance(context),
        control(context),
    )

    /** The app's files, cache, data directory and external files, each browsable. */
    public fun files(context: Context, extraRoots: List<NectoFilesPlugin.Root> = emptyList()): NectoFilesPlugin {
        val roots = buildList {
            add(NectoFilesPlugin.Root("files", "files", context.filesDir))
            add(NectoFilesPlugin.Root("cache", "cache", context.cacheDir))
            // shared_prefs, databases and no_backup live here.
            add(NectoFilesPlugin.Root("data", "data", context.dataDir))
            context.getExternalFilesDir(null)?.let { add(NectoFilesPlugin.Root("external", "external files", it)) }
            context.externalCacheDir?.let { add(NectoFilesPlugin.Root("external-cache", "external cache", it)) }
            addAll(extraRoots)
        }
        return NectoFilesPlugin(roots)
    }

    /** CPU, memory, frame rate and thread count, sampled only while a panel watches. */
    public fun performance(context: Context, metrics: List<NectoMetric> = emptyList()): NectoPerformancePlugin =
        NectoPerformancePlugin(metrics, NectoAndroidProcessSampler(context))

    /** Tap, type, swipe and go back in the foreground activity's View hierarchy. */
    public fun control(context: Context): NectoUIControlPlugin {
        NectoAndroid.track(context.applicationContext as Application)
        val runtime = NectoAndroidControlRuntime { NectoAndroid.currentActivity }
        return NectoUIControlPlugin(
            actionTargets = { runtime.snapshot() },
            readAccessibility = { runtime.readAccessibility() },
            action = { operation, input -> runtime.perform(operation, input) },
        )
    }
}
