// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample.fixture

import android.os.Handler
import android.os.Looper
import android.view.ViewConfiguration

/**
 * Tells how many fingers came down together and how many times in a row, the way the
 * iOS fixture's fifteen tap recognizers do: a lower count waits until a higher one can
 * no longer follow, so a triple tap is reported once rather than as one, two and three.
 *
 * Android has no tap recognizers to declare, so the View and Compose fixtures both feed
 * raw pointer changes in here. Call [down] when the first finger lands, [pointers] as
 * more join, and [up] when the last one lifts. Main thread only.
 */
internal class MultiTapCounter(private val onGesture: (fingers: Int, taps: Int) -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private val report = Runnable { flush() }
    private var fingers = 0
    private var taps = 0
    private var gestureFingers = 0

    fun down() {
        handler.removeCallbacks(report)
        gestureFingers = 1
    }

    fun pointers(count: Int) {
        gestureFingers = maxOf(gestureFingers, count)
    }

    fun up() {
        if (taps > 0 && gestureFingers == fingers) {
            taps += 1
        } else {
            flush()
            fingers = gestureFingers
            taps = 1
        }
        if (taps >= MAX_TAPS) flush() else handler.postDelayed(report, ViewConfiguration.getDoubleTapTimeout().toLong())
    }

    fun cancel() {
        handler.removeCallbacks(report)
        taps = 0
    }

    private fun flush() {
        handler.removeCallbacks(report)
        if (taps > 0) onGesture(fingers, taps)
        taps = 0
    }

    private companion object {
        const val MAX_TAPS = 3
    }
}

/** The fixture's status line, the same words on both platforms so one script checks both. */
internal fun fixtureStatus(taps: Int, navigation: Int, trap: Int, gesture: Int): String =
    "Taps: $taps · Nav: $navigation · Trap: $trap · Gesture: $gesture"

internal fun gestureStatus(fingers: Int, taps: Int): String = "Gesture: $fingers fingers × $taps taps"

internal fun positionStatus(x: Float, y: Float): String = String.format(java.util.Locale.US, "Tap position: %.2f, %.2f", x, y)
