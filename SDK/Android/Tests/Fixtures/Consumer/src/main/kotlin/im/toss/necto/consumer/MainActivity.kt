// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.consumer

import android.app.Activity
import android.os.Bundle
import android.widget.Button

class MainActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        var taps = 0
        setContentView(Button(this).apply {
            text = "Taps: 0"
            setOnClickListener { text = "Taps: ${++taps}" }
        })
    }
}
