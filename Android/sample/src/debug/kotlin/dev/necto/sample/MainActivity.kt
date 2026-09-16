// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sample

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val events get() = (application as SampleApplication).events
    private var count = 0
    private val heartbeat = object : Runnable {
        override fun run() {
            events.report("Android heartbeat", tag = "Lifecycle", level = "debug")
            handler.postDelayed(this, 2000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            addView(TextView(this@MainActivity).apply { text = "Necto Android sample" })
            addView(Button(this@MainActivity).apply {
                text = "Send event to Necto"
                setOnClickListener {
                    count += 1
                    events.report("Button tapped $count", tag = "Interaction", detail = mapOf("count" to count.toString()))
                }
            })
        })
    }

    override fun onStart() {
        super.onStart()
        handler.post(heartbeat)
    }

    override fun onStop() {
        handler.removeCallbacks(heartbeat)
        super.onStop()
    }
}
