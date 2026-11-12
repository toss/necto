// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.consumer

import android.app.Application
import im.toss.necto.android.NectoAndroid

object NectoSetup {
    fun start(app: Application) {
        NectoAndroid.start(app, selectedPlugins(app))
    }
}
