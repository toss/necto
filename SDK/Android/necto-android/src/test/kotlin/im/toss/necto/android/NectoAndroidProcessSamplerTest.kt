// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NectoAndroidProcessSamplerTest {
    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun aReadingRightAfterStartHasNoFrameRate() = runTest {
        val sampler = NectoAndroidProcessSampler(ApplicationProvider.getApplicationContext())
        sampler.start()

        val reading = sampler.snapshot()

        assertFalse("no frame rate before a second of frames", "fps" in reading.values)
        assertTrue("other metrics are there from the start", "memory" in reading.values)
        sampler.stop()
    }

    @Test
    fun frameRateAppearsAfterAFullSecondAndIsForgottenOnStop() {
        val monitor = FrameRateMonitor()
        monitor.start()
        val start = 1_000_000_000L
        val frame = 1_000_000_000L / 120

        // Just under a second of frames: still nothing to report.
        for (index in 0..120) monitor.doFrame(start + index * frame)
        assertNull(monitor.framesPerSecond)

        monitor.doFrame(start + 121 * frame)
        assertEquals(120.0, monitor.framesPerSecond!!, 1.0)

        monitor.stop()
        assertNull(monitor.framesPerSecond)
    }
}
