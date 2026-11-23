// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.ktor

import im.toss.necto.plugins.NectoNetworkRecord
import im.toss.necto.plugins.NectoNetworkReporting
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.plugins.HttpRequestRetry
import io.ktor.client.plugins.cache.HttpCache
import io.ktor.client.plugins.compression.ContentEncoding
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.prepareGet
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteChannel
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.ByteWriteChannel
import io.ktor.utils.io.readAvailable
import io.ktor.utils.io.writeFully
import io.ktor.utils.io.writeStringUtf8
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.zip.GZIPOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NectoKtorCaptureTest {
    private val records = mutableListOf<NectoNetworkRecord>()
    private val reporter = object : NectoNetworkReporting {
        override fun report(record: NectoNetworkRecord) {
            synchronized(records) { records += record }
        }
    }

    private fun client(handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData) =
        HttpClient(MockEngine(handler)) { install(NectoKtorCapture(reporter)) }

    @Test
    fun reportsPendingThenCompletedWithBodies() = runBlocking {
        var received = ""
        val client = client { request ->
            received = String(request.body.toByteArray())
            respond("""{"ok":true}""", HttpStatusCode.Created, headersOf(HttpHeaders.ContentType, "application/json"))
        }

        val body = client.post("https://example.com/v1/items?page=2") {
            header("X-Trace", "abc")
            setBody(TextContent("""{"name":"x"}""", ContentType.Application.Json))
        }.bodyAsText()
        assertEquals("""{"ok":true}""", body, "the app still reads the whole body")
        assertEquals("""{"name":"x"}""", received, "the engine still sends the whole body")

        val (pending, completed) = finished(1).let { listOf(records.first(), it.single()) }
        assertEquals(pending.id, completed.id)
        assertEquals(NectoNetworkRecord.State.PENDING, pending.state)
        assertNull(pending.requestBody)
        assertEquals("POST", completed.method)
        assertEquals(201, completed.statusCode)
        assertEquals("items?page=2", completed.name)
        assertEquals("abc", completed.requestHeaders["X-Trace"])
        assertEquals("application/json", completed.requestHeaders[HttpHeaders.ContentType])
        assertEquals("""{"name":"x"}""", completed.requestBody?.text)
        assertEquals("""{"ok":true}""", completed.responseBody?.text)
        assertEquals("application/json", completed.responseHeaders[HttpHeaders.ContentType])
        assertEquals(11L, completed.responseByteCount)
        assertTrue(completed.durationMilliseconds!! >= 0)
    }

    @Test
    fun largeBodiesAreCappedButDeliveredWhole() = runBlocking {
        val big = "a".repeat(NectoNetworkRecord.Body.CAPTURE_LIMIT + 10)
        val client = client { respond(big, headers = headersOf(HttpHeaders.ContentType, "text/plain")) }

        val body = client.get("https://example.com/big").bodyAsText()

        assertEquals(big.length, body.length)
        val completed = finished(1).single()
        assertTrue(completed.responseBody!!.isTruncated)
        assertEquals(big.length.toLong(), completed.responseByteCount)
        assertEquals(NectoNetworkRecord.Body.CAPTURE_LIMIT, completed.responseBody!!.text!!.length)
    }

    @Test
    fun failuresAreReportedAndRethrown() = runBlocking {
        val client = client { throw IOException("connection reset") }

        assertFailsWith<IOException> { client.get("https://example.com/down") }

        val failed = finished(1).single()
        assertEquals(NectoNetworkRecord.State.FAILED, failed.state)
        assertEquals("connection reset", failed.errorSummary)
        assertNull(failed.statusCode)
    }

    @Test
    fun aCancelledRequestIsReportedAsFailed() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val client = client {
            started.complete(Unit)
            delay(60_000)
            respond("late")
        }

        val call = launch { client.get("https://example.com/slow") }
        started.await()
        call.cancelAndJoin()

        assertEquals(NectoNetworkRecord.State.FAILED, finished(1).single().state)
    }

    /** A stream reaches the app as it arrives; the record waits for its end, not the other way round. */
    @Test
    fun slowStreamsReachTheAppWithoutWaitingForTheEnd() = runBlocking {
        val stream = ByteChannel()
        val client = client { respond(stream, headers = headersOf(HttpHeaders.ContentType, "text/event-stream")) }

        val first = CompletableDeferred<String>()
        val reading = async {
            client.prepareGet("https://example.com/events").execute { response ->
                val channel = response.bodyAsChannel()
                val buffer = ByteArray(64)
                val read = channel.readAvailable(buffer, 0, buffer.size)
                first.complete(String(buffer, 0, read))
                while (channel.readAvailable(buffer, 0, buffer.size) != -1) Unit
            }
        }
        stream.writeStringUtf8("data: one\n\n")
        stream.flush()

        assertEquals("data: one\n\n", withTimeout(5_000) { first.await() })
        assertTrue(synchronized(records) { records.none { it.state != NectoNetworkRecord.State.PENDING } })

        stream.writeStringUtf8("data: two\n\n")
        stream.flushAndClose()
        reading.await()

        val completed = finished(1).single()
        assertEquals(NectoNetworkRecord.State.COMPLETED, completed.state)
        assertEquals("data: one\n\ndata: two\n\n", completed.responseBody?.text)
    }

    @Test
    fun aStreamedUploadIsCapturedAsItIsSent() = runBlocking {
        var received = ByteArray(0)
        val client = client { request ->
            received = request.body.toByteArray()
            respond("ok")
        }
        val chunk = ByteArray(64 * 1024) { (it % 251).toByte() }
        val upload = object : OutgoingContent.WriteChannelContent() {
            override val contentType = ContentType.Application.OctetStream
            override suspend fun writeTo(channel: ByteWriteChannel) {
                repeat(4) { channel.writeFully(chunk) }
            }
        }

        client.post("https://example.com/upload") { setBody(upload) }.bodyAsText()

        assertEquals(4 * chunk.size, received.size, "the engine still receives every byte")
        val completed = finished(1).single()
        assertEquals(4L * chunk.size, completed.requestBody?.byteCount)
        assertNull(completed.requestBody?.text, "binary uploads keep no text")
    }

    @Test
    fun aChannelUploadIsCapturedAsItIsSent() = runBlocking {
        var received = ""
        val client = client { request ->
            received = String(request.body.toByteArray())
            respond("ok")
        }

        client.post("https://example.com/upload") {
            setBody(ByteReadChannel("line one\nline two\n"))
            header(HttpHeaders.ContentType, "text/plain")
        }.bodyAsText()

        assertEquals("line one\nline two\n", received)
        assertEquals("line one\nline two\n", finished(1).single().requestBody?.text)
    }

    /** What the app reads is decoded, and so is what Necto shows. */
    @Test
    fun gzipResponsesAreCapturedDecoded() = runBlocking {
        val text = """{"compressed":true}"""
        val gzipped = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(text.toByteArray()) } }.toByteArray()
        val client = HttpClient(MockEngine {
            respond(gzipped, headers = headersOf(HttpHeaders.ContentEncoding to listOf("gzip"), HttpHeaders.ContentType to listOf("application/json")))
        }) {
            install(ContentEncoding) { gzip() }
            install(NectoKtorCapture(reporter))
        }

        assertEquals(text, client.get("https://example.com/gzip").bodyAsText())

        assertEquals(text, finished(1).single().responseBody?.text)
    }

    @Test
    fun eachHopOfARedirectIsItsOwnRecord() = runBlocking {
        val client = client { request ->
            if (request.url.encodedPath == "/old") {
                respond("", HttpStatusCode.Found, headersOf(HttpHeaders.Location, "https://example.com/new"))
            } else {
                respond("here")
            }
        }

        assertEquals("here", client.get("https://example.com/old").bodyAsText())

        val (moved, arrived) = finished(2).sortedBy { it.url }.reversed()
        assertNotEquals(moved.id, arrived.id)
        assertEquals(302, moved.statusCode)
        assertEquals(200, arrived.statusCode)
        assertEquals("here", arrived.responseBody?.text)
    }

    /** HttpCache answers before the engine, so the observer never sees the response. */
    @Test
    fun aCachedResponseStillCompletes() = runBlocking {
        val client = HttpClient(MockEngine {
            respond("cached", headers = headersOf(HttpHeaders.CacheControl, "max-age=60"))
        }) {
            install(HttpCache)
            install(NectoKtorCapture(reporter))
        }

        client.get("https://example.com/cached").bodyAsText()
        assertEquals("cached", client.get("https://example.com/cached").bodyAsText())

        val (first, second) = finished(2)
        assertEquals("cached", first.responseBody?.text)
        assertEquals(NectoNetworkRecord.State.COMPLETED, second.state)
        assertEquals(200, second.statusCode)
    }

    /** Installed after the retry plugin, each attempt is its own record and the last answer shows. */
    @Test
    fun eachRetryIsItsOwnRecordWhenInstalledAfterTheRetryPlugin() = runBlocking {
        var attempts = 0
        val client = HttpClient(MockEngine {
            if (attempts++ == 0) respond("busy", HttpStatusCode.ServiceUnavailable) else respond("fine")
        }) {
            install(HttpRequestRetry) {
                retryOnServerErrors(maxRetries = 1)
                constantDelay(millis = 1)
            }
            install(NectoKtorCapture(reporter))
        }

        assertEquals("fine", client.get("https://example.com/flaky").bodyAsText())

        assertEquals(listOf(503, 200), finished(2).map { it.statusCode })
    }

    /** When the engine gives up on an upload, the app's producer stops too instead of waiting forever. */
    @Test
    fun aFailedUploadStopsTheAppsProducer() = runBlocking {
        val client = client { request ->
            (request.body as OutgoingContent.ReadChannelContent).readFrom().cancel(IOException("reset"))
            throw IOException("connection reset")
        }
        val upload = ByteChannel()
        val stopped = CompletableDeferred<Throwable>()
        launch {
            val chunk = ByteArray(8 * 1024)
            try {
                while (true) {
                    upload.writeFully(chunk)
                    upload.flush()
                }
            } catch (error: Throwable) {
                stopped.complete(error)
            }
        }

        assertFailsWith<IOException> {
            client.post("https://example.com/upload") { setBody(upload) }
        }

        withTimeout(5_000) { stopped.await() }
        assertEquals(NectoNetworkRecord.State.FAILED, finished(1).single().state)
    }

    @Test
    fun aReporterThatThrowsDoesNotBreakTheRequest() = runBlocking {
        val client = HttpClient(MockEngine { respond("fine") }) {
            install(NectoKtorCapture(object : NectoNetworkReporting {
                override fun report(record: NectoNetworkRecord) = throw IllegalStateException("broken reporter")
            }))
        }

        assertEquals("fine", client.get("https://example.com/").bodyAsText())
    }

    /** The finished report comes from the observer's copy, after the app has its response. */
    private suspend fun finished(count: Int): List<NectoNetworkRecord> {
        withTimeout(5_000) {
            while (synchronized(records) { records.count { it.state != NectoNetworkRecord.State.PENDING } } < count) delay(10)
        }
        delay(50)
        return synchronized(records) { records.filter { it.state != NectoNetworkRecord.State.PENDING } }
            .also { assertEquals(count, it.size, "one finished report per request: $it") }
    }
}
