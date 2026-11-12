// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoSDK

/**
 * Supplies the app's identity to [NectoSDK], registers selected plugins and starts listening.
 *
 * ```kotlin
 * class App : Application() {
 *     override fun onCreate() {
 *         super.onCreate()
 *         if (BuildConfig.DEBUG) NectoAndroid.start(this)
 *     }
 * }
 * ```
 *
 * The app then waits on a private Unix socket that only ADB can reach. Necto on the Mac
 * finds it through ADB and forwards a private socket of its own to it.
 *
 * Necto runs in debuggable builds only: a release build is never reachable through
 * `adb shell run-as`, which is how the host finds the socket, and it should not carry a
 * debugging bridge anyway.
 */
public object NectoAndroid {
    /**
     * Starts Necto with the explicitly selected [plugins]. No plugins are added by default.
     * Safe to call more than once; plugins already registered are skipped. In a build
     * that is not debuggable it only logs a warning.
     */
    public fun start(
        context: Context,
        plugins: List<NectoPlugin> = emptyList(),
    ) {
        val application = context.applicationContext as Application
        if (application.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            Log.w(TAG, "Necto runs in debuggable builds only; not starting")
            return
        }
        NectoSDK.identity = NectoAndroidAppIdentity(application)
        plugins.forEach { plugin ->
            if (NectoSDK.plugins.none { it.id == plugin.id }) NectoSDK.register(plugin)
        }
        NectoSDK.start { NectoAndroidListener(application) }
    }

    public fun stop() {
        NectoSDK.stop()
    }

    private const val TAG = "Necto"
}
