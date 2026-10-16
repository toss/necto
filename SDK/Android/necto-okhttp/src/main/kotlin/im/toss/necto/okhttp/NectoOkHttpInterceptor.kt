// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.okhttp

import im.toss.necto.plugins.NectoNetworkPlugin
import im.toss.necto.plugins.NectoNetworkRecord
import im.toss.necto.plugins.NectoNetworkReporting
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.Buffer
import okio.ForwardingSource
import okio.Sink
import okio.Source
import okio.Timeout
import okio.buffer
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The network plugin with OkHttp capture ready to wire, the counterpart of the iOS
 * `URLSessionNetworkPlugin`.
 *
 * ```kotlin
 * val network = OkHttpNetworkPlugin()
 * NectoSDK.register(network)
 * val client = OkHttpClient.Builder().addInterceptor(network.interceptor).build()
 * ```
 *
 * An app that reports some requests itself as well reaches the plugin through [network].
 */
public class OkHttpNetworkPlugin(public val network: NectoNetworkPlugin = NectoNetworkPlugin()) : NectoPlugin {
    override val id: String get() = network.id
    override val panel: NectoPluginPanel get() = network.panel

    /** Add as an application interceptor, so bodies are seen decompressed. */
    public val interceptor: NectoOkHttpInterceptor = NectoOkHttpInterceptor(network)

    override fun register(necto: NectoRegistrar) {
        network.register(necto)
    }
}

/**
 * Captures OkHttp traffic and reports it to whatever takes reports.
 *
 * It only observes: the request goes through unchanged and the response body reaches
 * the app as it arrives. Bytes are copied while the app reads them, up to
 * [NectoNetworkRecord.Body.CAPTURE_LIMIT], and the record completes when the app reaches
 * the end of the body or closes it, so streams such as server-sent events are never held
 * back. A body the app never reads or closes leaves its record pending.
 */
public class NectoOkHttpInterceptor(private val reporter: NectoNetworkReporting) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val id = UUID.randomUUID().toString().uppercase()
        val startedAt = System.currentTimeMillis()
        val startedNanos = System.nanoTime()

        fun record(
            state: NectoNetworkRecord.State,
            response: Response? = null,
            error: Throwable? = null,
            responseBody: NectoNetworkRecord.Body? = null,
        ): NectoNetworkRecord = NectoNetworkRecord(
            id = id,
            method = request.method,
            url = request.url.toString(),
            startedAtMilliseconds = startedAt.toDouble(),
            state = state,
            statusCode = response?.code,
            durationMilliseconds = if (state == NectoNetworkRecord.State.PENDING) null else (System.nanoTime() - startedNanos) / 1_000_000.0,
            responseByteCount = if (state == NectoNetworkRecord.State.COMPLETED) responseBody?.byteCount ?: 0 else null,
            errorSummary = error?.let { it.message ?: it.toString() },
            requestHeaders = headers(request.headers),
            responseHeaders = response?.let { headers(it.headers) }.orEmpty(),
            // A pending record carries no body yet: sending it twice would double the
            // traffic for large uploads.
            requestBody = if (state == NectoNetworkRecord.State.PENDING) null else requestBody(request),
            responseBody = responseBody,
        )

        safely { reporter.report(record(NectoNetworkRecord.State.PENDING)) }

        val response = try {
            chain.proceed(request)
        } catch (error: Throwable) {
            // Not only IOException: a later interceptor's RuntimeException would otherwise
            // leave the record pending forever.
            safely { reporter.report(record(NectoNetworkRecord.State.FAILED, error = error)) }
            throw error
        }

        val body = response.body
        if (body == null) {
            safely { reporter.report(record(NectoNetworkRecord.State.COMPLETED, response = response)) }
            return response
        }
        val type = response.header("Content-Type") ?: body.contentType()?.toString()
        val capturing = CapturingSource(body.source(), body.contentLength()) { bytes, byteCount ->
            safely {
                val captured = if (bytes.isEmpty()) null else NectoNetworkRecord.Body.of(bytes, type, byteCount = byteCount)
                reporter.report(record(NectoNetworkRecord.State.COMPLETED, response = response, responseBody = captured))
            }
        }
        return response.newBuilder()
            .body(capturing.buffer().asResponseBody(body.contentType(), body.contentLength()))
            .build()
    }

    /** Capture never breaks the request it observes. */
    private inline fun safely(block: () -> Unit) {
        try {
            block()
        } catch (_: Exception) {
        }
    }

    private fun headers(headers: Headers): Map<String, String> =
        headers.names().associateWith { name -> headers.values(name).joinToString(", ") }

    private fun requestBody(request: Request): NectoNetworkRecord.Body? {
        val body = request.body ?: return null
        // Duplex and one-shot bodies can only be written once, and that write is the app's.
        if (body.isDuplex() || body.isOneShot()) return null
        // Keeps the first bytes and only counts the rest, so a large upload is never
        // held in memory whole.
        val sink = CappedSink(NectoNetworkRecord.Body.CAPTURE_LIMIT.toLong())
        sink.buffer().use { body.writeTo(it) }
        val bytes = sink.kept.readByteArray()
        if (bytes.isEmpty()) return null
        return NectoNetworkRecord.Body.of(bytes, body.contentType()?.toString(), byteCount = sink.count)
    }
}

/** Copies up to the capture limit of what the app reads, then reports once at EOF or close. */
private class CapturingSource(
    delegate: Source,
    private val declaredLength: Long,
    private val onDone: (bytes: ByteArray, byteCount: Long) -> Unit,
) : ForwardingSource(delegate) {
    private val limit = NectoNetworkRecord.Body.CAPTURE_LIMIT.toLong()
    private val captured = Buffer()
    private var count = 0L
    private val done = AtomicBoolean(false)

    override fun read(sink: Buffer, byteCount: Long): Long {
        val read = super.read(sink, byteCount)
        if (read == -1L) {
            finish()
            return read
        }
        val wanted = minOf(read, limit - captured.size)
        if (wanted > 0) sink.copyTo(captured, sink.size - read, wanted)
        count += read
        return read
    }

    override fun close() {
        if (!done.get()) captureRest()
        finish()
        super.close()
    }

    /**
     * An app that closes a body unread (checking only the status, say) would otherwise leave
     * nothing captured. Like OkHttp discarding an unfinished body, read what remains up to
     * the capture limit, but only briefly, so a stream is never waited on.
     */
    private fun captureRest() {
        val timeout = delegate.timeout()
        val previous = if (timeout.hasDeadline()) timeout.deadlineNanoTime() else null
        try {
            timeout.deadline(DRAIN_MILLIS, TimeUnit.MILLISECONDS)
            val scratch = Buffer()
            while (captured.size < limit) {
                val read = delegate.read(scratch, limit - captured.size)
                if (read == -1L) break
                count += read
                captured.write(scratch, read)
            }
        } catch (_: Exception) {
        } finally {
            if (previous != null) timeout.deadlineNanoTime(previous) else timeout.clearDeadline()
        }
    }

    private fun finish() {
        if (!done.compareAndSet(false, true)) return
        onDone(captured.readByteArray(), maxOf(count, declaredLength))
    }

    private companion object {
        const val DRAIN_MILLIS = 100L
    }
}

private class CappedSink(private val limit: Long) : Sink {
    val kept = Buffer()
    var count = 0L
        private set

    override fun write(source: Buffer, byteCount: Long) {
        val keep = minOf(byteCount, limit - kept.size)
        if (keep > 0) kept.write(source, keep)
        source.skip(byteCount - maxOf(keep, 0))
        count += byteCount
    }

    override fun flush() = Unit
    override fun timeout(): Timeout = Timeout.NONE
    override fun close() = Unit
}
