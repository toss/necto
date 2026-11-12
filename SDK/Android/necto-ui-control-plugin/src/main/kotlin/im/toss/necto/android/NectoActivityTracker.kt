// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.lang.ref.WeakReference

internal object NectoActivityTracker {
    @Volatile
    private var resumed: WeakReference<Activity>? = null

    @Volatile
    private var tracking = false

    /** The activity in the foreground, if any. UI Control acts on its window. */
    val currentActivity: Activity? get() = resumed?.get()

    fun track(application: Application) {
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
