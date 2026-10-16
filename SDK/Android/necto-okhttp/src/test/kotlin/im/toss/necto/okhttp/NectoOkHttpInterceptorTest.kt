// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.okhttp

import im.toss.necto.plugins.NectoNetworkRecord
import im.toss.necto.plugins.NectoNetworkReporting
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NectoOkHttpInterceptorTest {
    private val server = MockWebServer().apply { start() }
    private val records = mutableListOf<NectoNetworkRecord>()
    private val reporter = object : NectoNetworkReporting {
        override fun report(record: NectoNetworkRecord) {
            synchronized(records) { records += record }
        }
    }
    private val client = OkHttpClient.Builder().addInterceptor(NectoOkHttpInterceptor(reporter)).build()

    @AfterTest
    fun tearDown() = server.shutdown()

    @Test
    fun reportsPendingThenCompletedWithBodies() {
        server.enqueue(MockResponse().setResponseCode(201).setHeader("Content-Type", "application/json").setBody("""{"ok":true}"""))
        val request = Request.Builder()
            .url(server.url("/v1/items?page=2"))
            .header("X-Trace", "abc")
            .post("""{"name":"x"}""".toRequestBody("application/json".toMediaType()))
            .build()

        val body = client.newCall(request).execute().use { it.body!!.string() }
        assertEquals("""{"ok":true}""", body, "the app still reads the whole body")

        assertEquals(2, records.size)
        val (pending, completed) = records
        assertEquals(pending.id, completed.id)
        assertEquals(NectoNetworkRecord.State.PENDING, pending.state)
        assertNull(pending.requestBody)
        assertEquals(NectoNetworkRecord.State.COMPLETED, completed.state)
        assertEquals(201, completed.statusCode)
        assertEquals("items?page=2", completed.name)
        assertEquals("abc", completed.requestHeaders["X-Trace"])
        assertEquals("""{"name":"x"}""", completed.requestBody?.text)
        assertEquals("""{"ok":true}""", completed.responseBody?.text)
        assertEquals(11L, completed.responseByteCount)
        assertTrue(completed.durationMilliseconds!! >= 0)
    }

    @Test
    fun largeBodiesAreCappedButDeliveredWhole() {
        val big = "a".repeat(NectoNetworkRecord.Body.CAPTURE_LIMIT + 10)
        server.enqueue(MockResponse().setHeader("Content-Type", "text/plain").setBody(big))
        val body = client.newCall(Request.Builder().url(server.url("/big")).build()).execute().use { it.body!!.string() }
        assertEquals(big.length, body.length)
        val completed = records.last()
        assertTrue(completed.responseBody!!.isTruncated)
        assertEquals(NectoNetworkRecord.Body.CAPTURE_LIMIT, completed.responseBody!!.text!!.length)
    }

    @Test
    fun failuresAreReportedAndRethrown() {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        assertFailsWith<IOException> {
            client.newCall(Request.Builder().url(server.url("/down")).build()).execute()
        }
        assertEquals(NectoNetworkRecord.State.FAILED, records.last().state)
        assertTrue(records.last().errorSummary!!.isNotEmpty())
    }

    @Test
    fun slowStreamsReachTheAppWithoutWaitingForTheCaptureLimit() {
        // 1 KB a second: waiting for 512 KB up front would take minutes.
        server.enqueue(
            MockResponse().setHeader("Content-Type", "text/event-stream")
                .setBody("data: first\n\n" + "x".repeat(64 * 1024))
                .throttleBody(1024, 1, TimeUnit.SECONDS),
        )
        val started = System.nanoTime()
        client.newCall(Request.Builder().url(server.url("/events")).build()).execute().use { response ->
            assertEquals("data: first", response.body!!.source().readUtf8Line())
        }
        assertTrue(System.nanoTime() - started < TimeUnit.SECONDS.toNanos(5), "the first event arrives at once")
        val completed = records.last()
        assertEquals(NectoNetworkRecord.State.COMPLETED, completed.state)
        assertTrue(completed.responseBody!!.text!!.startsWith("data: first"))
    }

    @Test
    fun largeUploadsAreCountedButCapped() {
        server.enqueue(MockResponse())
        val size = NectoNetworkRecord.Body.CAPTURE_LIMIT * 3
        val request = Request.Builder().url(server.url("/upload"))
            .post(ByteArray(size).toRequestBody("application/octet-stream".toMediaType()))
            .build()
        client.newCall(request).execute().close()
        val body = records.last().requestBody!!
        assertTrue(body.isTruncated)
        assertEquals(size.toLong(), body.byteCount)
    }

    @Test
    fun runtimeExceptionsFromLaterInterceptorsAreReportedAsFailures() {
        val failing = OkHttpClient.Builder()
            .addInterceptor(NectoOkHttpInterceptor(reporter))
            .addInterceptor { throw IllegalStateException("boom") }
            .build()
        assertFailsWith<IllegalStateException> {
            failing.newCall(Request.Builder().url(server.url("/x")).build()).execute()
        }
        assertEquals(NectoNetworkRecord.State.FAILED, records.last().state)
    }

    @Test
    fun bodiesClosedUnreadAreStillCaptured() {
        server.enqueue(MockResponse().setHeader("Content-Type", "text/plain").setBody("hello"))
        val code = client.newCall(Request.Builder().url(server.url("/status-only")).build()).execute().use { it.code }
        assertEquals(200, code)
        val completed = records.last()
        assertEquals("hello", completed.responseBody?.text)
        assertEquals(5L, completed.responseByteCount)
    }
}
