// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoControlGeometry
import im.toss.necto.plugins.NectoFilesPlugin
import im.toss.necto.plugins.NectoMetric
import im.toss.necto.plugins.NectoPerformancePlugin
import im.toss.necto.plugins.NectoPerformanceReading
import im.toss.necto.plugins.NectoPerformanceSampling
import im.toss.necto.plugins.NectoPoint
import im.toss.necto.plugins.NectoRect
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoRegistrar
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Calls a plugin's handlers directly, without a session. */
private class Harness(plugin: NectoPlugin) {
    private val registrar = NectoRegistrar().also(plugin::register)

    suspend fun call(name: String, input: NectoJsonValue = jsonObject()): NectoJsonValue {
        val body = registrar.registrations.getValue("necto.device.$name@1").body as NectoRegistrar.Body.Once
        return body.run(input)
    }
}

class PluginTests {
    private val directory: File = Files.createTempDirectory("necto").toFile()
    private val files = Harness(NectoFilesPlugin(listOf(NectoFilesPlugin.Root("files", "files", directory))))

    private fun input(vararg pairs: Pair<String, String>) = jsonObject(*pairs.map { it.first to jsonOf(it.second) }.toTypedArray())

    @Test
    fun filesListsPreviewsWritesAndDeletes() = runBlocking {
        File(directory, "logs").mkdirs()
        File(directory, "note.txt").writeText("hello")
        File(directory, "photo.png").writeBytes(byteArrayOf(1, 2, 3))
        File(directory, "blob.bin").writeBytes(byteArrayOf(0xC3.toByte(), 0x28))

        val entries = files.call("files.list", input("root" to "files"))["entries"]!!.arrayValue!!
        assertEquals(listOf("logs", "blob.bin", "note.txt", "photo.png"), entries.map { it["name"]!!.stringValue })
        assertEquals(jsonOf(0), entries[0]["itemCount"])

        val text = files.call("files.preview", input("root" to "files", "path" to "note.txt"))["file"]!!
        assertEquals(jsonOf("text"), text["kind"])
        assertEquals(jsonOf("hello"), text["text"])
        assertEquals(jsonOf(false), text["isTruncated"])

        val image = files.call("files.preview", input("root" to "files", "path" to "photo.png"))["file"]!!
        assertEquals(jsonOf("image/png"), image["mediaType"])
        assertEquals(jsonOf("AQID"), image["base64"])

        assertEquals(jsonOf("binary"), files.call("files.preview", input("root" to "files", "path" to "blob.bin"))["file"]!!["kind"])

        files.call("files.write", jsonObject("root" to jsonOf("files"), "path" to jsonOf("logs/new.txt"), "content" to jsonOf("é")))
        assertEquals("é", File(directory, "logs/new.txt").readText())

        files.call("files.delete", input("root" to "files", "path" to "logs"))
        assertFalse(File(directory, "logs").exists())
        Unit
    }

    @Test
    fun filesRefusesPathsOutsideTheRoot() = runBlocking {
        for (path in listOf("../etc/passwd", "/etc/passwd", "a/../../x")) {
            val error = assertFailsWith<NectoBridgeError> { files.call("files.info", input("root" to "files", "path" to path)) }
            assertEquals(NectoBridgeErrorCode.INVALID_INPUT, error.code)
        }
        assertFailsWith<NectoBridgeError> { files.call("files.delete", input("root" to "files", "path" to ".")) }
        assertFailsWith<NectoBridgeError> { files.call("files.list", input("root" to "other")) }
        assertTrue(directory.exists())
    }

    @Test
    fun textPreviewSurvivesACutMultibyteCharacter() {
        val bytes = "가나".toByteArray()
        assertEquals("가", NectoFilesPlugin.decodeUtf8Head(bytes.copyOf(4), isComplete = false))
        assertEquals(null, NectoFilesPlugin.decodeUtf8Head(bytes.copyOf(4), isComplete = true))
    }

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
            val registrar = NectoRegistrar().also(NectoPerformancePlugin(sampler = sampler)::register)
            val observe = registrar.registrations.getValue("necto.device.performance.observe@1").body as NectoRegistrar.Body.Stream

            val subscriber = launch { observe.run(jsonObject("interval" to jsonOf(0.1))) { } }
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
        val harness = Harness(plugin)
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

    @Test
    fun controlGeometryMatchesTheSwiftRules() {
        val frame = NectoRect(0.0, 0.0, 100.0, 50.0)
        assertEquals(NectoPoint(25.0, 25.0), NectoControlGeometry.position(jsonObject("x" to jsonOf(0.25), "y" to jsonOf(0.5)), frame))
        assertEquals(NectoPoint(99.5, 49.5), NectoControlGeometry.position(jsonObject("x" to jsonOf(1), "y" to jsonOf(1)), frame))
        assertFailsWith<NectoBridgeError> { NectoControlGeometry.position(jsonObject("x" to jsonOf(2), "y" to jsonOf(0)), frame) }
        assertEquals(NectoPoint(50.0, 0.5), NectoControlGeometry.swipe(NectoPoint(50.0, 25.0), "up", 0.9, frame))
        val points = NectoControlGeometry.tapPoints(NectoPoint(50.0, 25.0), 3, frame)
        assertEquals(listOf(26.0, 50.0, 74.0), points.map { it.x })
    }
}
