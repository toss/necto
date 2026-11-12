// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoMetric
import im.toss.necto.plugins.NectoPerformancePlugin
import im.toss.necto.plugins.NectoPerformanceReading
import im.toss.necto.plugins.NectoPerformanceSampling
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import im.toss.necto.testing.PluginHarness

class PerformancePluginTests {

    @Test
    fun aFailingSamplerStopsSamplingWithoutCrashingTheApp() = runBlocking {
        val uncaught = mutableListOf<Throwable>()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, error -> synchronized(uncaught) { uncaught += error } }
        try {
            var stopped = false
            val sampler = object : NectoPerformanceSampling {
                override val metrics = listOf(NectoMetric("fps", "Frame rate", "fps"))
                override suspend fun start() = Unit
                override suspend fun stop() { stopped = true }
                override suspend fun snapshot(): NectoPerformanceReading = error("sampler bug")
                override suspend fun detail(): NectoJsonValue = jsonObject()
            }
            val harness = PluginHarness(NectoPerformancePlugin(sampler = sampler))

            val subscriber = launch { harness.observe("performance.observe", jsonObject("interval" to jsonOf(0.1))) { } }
            delay(500)
            subscriber.cancel()

            assertTrue(stopped, "the sampler is stopped after it fails")
            assertTrue(uncaught.isEmpty(), "nothing reached the uncaught exception handler: $uncaught")
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(previous)
        }
    }

    @Test
    fun performanceKeepsSeriesAndJudgesBudgets() = runBlocking {
        val plugin = NectoPerformancePlugin(listOf(NectoMetric("fps", "Frame rate", "fps", NectoMetric.Budget.AtLeast(55.0))))
        val harness = PluginHarness(plugin)
        plugin.report(60.0, "fps")
        plugin.report(40.0, "fps")
        plugin.report(1.0, "unknown")
        val series = harness.call("performance.series")["series"]!!.arrayValue!!.single()
        assertEquals(jsonOf(40), series["latest"])
        assertEquals(jsonOf(true), series["isOverBudget"])
        assertEquals(2, series["samples"]!!.arrayValue!!.size)
        val metric = harness.call("performance.metrics")["metrics"]!!.arrayValue!!.single()
        assertEquals(jsonOf("atLeast"), metric["budgetKind"])
        val error = assertFailsWith<NectoBridgeError> { harness.call("performance.snapshot") }
        assertEquals(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, error.code)
    }

}
