// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.consumer

import android.app.Application

class ConsumerApp : Application() {
    override fun onCreate() {
        super.onCreate()
        NectoSetup.start(this)
    }
}
