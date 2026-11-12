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
import okhttp3.MediaType
import okhttp3.RequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.Buffer
import okio.BufferedSink
import okio.ForwardingSink
import okio.ForwardingSource
import okio.Source
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
 * It only observes: the request's bytes go through unchanged and the response body reaches
 * the app as it arrives. Bytes are copied while the app reads them, up to
 * [NectoNetworkRecord.Body.CAPTURE_LIMIT], and the record completes when the app reaches
 * the end of the body or closes it, so streams such as server-sent events are never held
 * back. A body the app never reads or closes leaves its record pending.
 *
 * The request body is wrapped so its bytes are copied as OkHttp sends them. An
 * interceptor added after this one sees that wrapper rather than the app's
 * `FormBody` or `MultipartBody`, so add this one after any interceptor that inspects
 * body types. One that compresses the body before this one is captured compressed.
 */
public class NectoOkHttpInterceptor(private val reporter: NectoNetworkReporting) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        // The upload is copied as OkHttp sends it, so the record holds what went out. Reading
        // the body again later could see a file that has changed, or one that is gone.
        // Duplex bodies keep writing after the response, so they are not captured.
        val upload = original.body?.takeUnless { it.isDuplex() }?.let(::CapturingRequestBody)
        val request = if (upload == null) original else original.newBuilder().method(original.method, upload).build()
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
            requestBody = if (state == NectoNetworkRecord.State.PENDING) null else upload?.captured(),
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
        val capturing = CapturingSource(body.source(), body.contentLength()) { bytes, byteCount, error ->
            safely {
                val captured = if (bytes.isEmpty()) null else NectoNetworkRecord.Body.of(bytes, type, byteCount = byteCount)
                val state = if (error == null) NectoNetworkRecord.State.COMPLETED else NectoNetworkRecord.State.FAILED
                reporter.report(record(state, response = response, error = error, responseBody = captured))
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
}

/**
 * Passes a request body through unchanged and copies the bytes OkHttp writes, up to the
 * capture limit. Only the first bytes are kept and the rest counted, so a large upload
 * is never held in memory whole.
 */
private class CapturingRequestBody(private val delegate: RequestBody) : RequestBody() {
    @Volatile
    private var copy: CappedSink? = null

    override fun contentType(): MediaType? = delegate.contentType()
    override fun contentLength(): Long = delegate.contentLength()
    override fun isOneShot(): Boolean = delegate.isOneShot()
    override fun isDuplex(): Boolean = delegate.isDuplex()

    override fun writeTo(sink: BufferedSink) {
        // A retry or redirect writes the body again; the last write is what was sent.
        val capture = CappedSink(NectoNetworkRecord.Body.CAPTURE_LIMIT.toLong())
        copy = capture
        val tee = object : ForwardingSink(sink) {
            override fun write(source: Buffer, byteCount: Long) {
                capture.copyFrom(source, byteCount)
                super.write(source, byteCount)
            }
        }.buffer()
        delegate.writeTo(tee)
        // A body that closes its sink, as a gzip wrapper does, has already pushed it all through.
        if (tee.isOpen) tee.emit()
    }

    fun captured(): NectoNetworkRecord.Body? {
        val copy = copy ?: return null
        val bytes = copy.kept.snapshot().toByteArray()
        if (bytes.isEmpty()) return null
        return NectoNetworkRecord.Body.of(bytes, contentType()?.toString(), byteCount = copy.count)
    }
}

/**
 * Copies up to the capture limit of what the app reads, then reports once: at EOF or
 * close, or with the error when reading the body fails.
 */
private class CapturingSource(
    delegate: Source,
    private val declaredLength: Long,
    private val onDone: (bytes: ByteArray, byteCount: Long, error: Throwable?) -> Unit,
) : ForwardingSource(delegate) {
    private val limit = NectoNetworkRecord.Body.CAPTURE_LIMIT.toLong()
    private val captured = Buffer()
    private var count = 0L
    private val done = AtomicBoolean(false)

    override fun read(sink: Buffer, byteCount: Long): Long {
        val read = try {
            super.read(sink, byteCount)
        } catch (error: Throwable) {
            finish(error)
            throw error
        }
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

    private fun finish(error: Throwable? = null) {
        if (!done.compareAndSet(false, true)) return
        onDone(captured.readByteArray(), maxOf(count, declaredLength), error)
    }

    private companion object {
        const val DRAIN_MILLIS = 100L
    }
}

private class CappedSink(private val limit: Long) {
    val kept = Buffer()
    var count = 0L
        private set

    /** Copies from [source] without consuming it. */
    fun copyFrom(source: Buffer, byteCount: Long) {
        val keep = minOf(byteCount, limit - kept.size)
        if (keep > 0) source.copyTo(kept, 0, keep)
        count += byteCount
    }
}
