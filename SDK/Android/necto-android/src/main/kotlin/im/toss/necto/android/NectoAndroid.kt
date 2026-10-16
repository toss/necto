// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.util.Log
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoSDK
import java.lang.ref.WeakReference

/**
 * The Android entry point: supplies the app's identity to [NectoSDK], tracks the
 * foreground activity for UI Control, registers plugins and starts listening.
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
 * The app then waits on a private Unix socket that only ADB can reach. On the Mac,
 * `script/android-connect` forwards it and starts Necto pointed at it.
 *
 * Necto runs in debuggable builds only: a release build is never reachable through
 * `adb shell run-as`, which is how the host finds the socket, and it should not carry a
 * debugging bridge anyway.
 */
public object NectoAndroid {
    @Volatile
    private var resumed: WeakReference<Activity>? = null

    @Volatile
    private var tracking = false

    /** The activity in the foreground, if any. UI Control acts on its window. */
    public val currentActivity: Activity? get() = resumed?.get()

    /**
     * Starts Necto with [plugins], which default to every plugin Necto ships for Android.
     * Safe to call more than once; plugins already registered are skipped. In a build
     * that is not debuggable it only logs a warning.
     */
    public fun start(
        context: Context,
        plugins: List<NectoPlugin> = NectoAndroidPlugins.defaults(context),
    ) {
        val application = context.applicationContext as Application
        if (application.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            Log.w(TAG, "Necto runs in debuggable builds only; not starting")
            return
        }
        track(application)
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

    internal fun track(application: Application) {
        synchronized(this) {
            if (tracking) return
            tracking = true
        }
        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                resumed = WeakReference(activity)
            }

            override fun onActivityPaused(activity: Activity) {
                if (resumed?.get() === activity) resumed = null
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }
}
