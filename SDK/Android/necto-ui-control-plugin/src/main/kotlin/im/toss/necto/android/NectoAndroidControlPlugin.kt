// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.app.Application
import android.content.Context
import im.toss.necto.plugins.NectoUIControlPlugin
import im.toss.necto.sdk.NectoPlugin

/** UI Control for the foreground activity's Views and optional Compose content. */
public class NectoAndroidControlPlugin(context: Context) : NectoPlugin by controlPlugin(context)

private fun controlPlugin(context: Context): NectoPlugin {
    NectoActivityTracker.track(context.applicationContext as Application)
    val runtime = NectoAndroidControlRuntime { NectoActivityTracker.currentActivity }
    return NectoUIControlPlugin(
        actionTargets = { runtime.snapshot() },
        readAccessibility = { runtime.readAccessibility() },
        action = { operation, input -> runtime.perform(operation, input) },
    )
}
