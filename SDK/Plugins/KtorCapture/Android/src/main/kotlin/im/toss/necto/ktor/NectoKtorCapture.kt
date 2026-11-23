// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.ktor

import im.toss.necto.plugins.NectoNetworkPlugin
import im.toss.necto.plugins.NectoNetworkRecord
import im.toss.necto.plugins.NectoNetworkReporting
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar
import io.ktor.client.plugins.api.ClientPlugin
import io.ktor.client.plugins.api.Send
import io.ktor.client.plugins.api.createClientPlugin
import io.ktor.client.plugins.observer.ResponseObserver
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.util.AttributeKey
import io.ktor.util.reflect.typeInfo
import io.ktor.utils.io.ByteChannel
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.ByteWriteChannel
import io.ktor.utils.io.close
import io.ktor.utils.io.readAvailable
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The network plugin with Ktor capture ready to install, the counterpart of
 * `OkHttpNetworkPlugin`.
 *
 * ```kotlin
 * val network = KtorNetworkPlugin()
 * NectoSDK.register(network)
 * val client = HttpClient(CIO) { install(network.capture) }
 * ```
 *
 * An app that reports some requests itself as well reaches the plugin through [network].
 */
public class KtorNetworkPlugin(public val network: NectoNetworkPlugin = NectoNetworkPlugin()) : NectoPlugin {
    override val id: String get() = network.id
    override val panel: NectoPluginPanel get() = network.panel

    /** Install in each `HttpClient` whose requests should appear in Necto. */
    public val capture: ClientPlugin<Unit> = NectoKtorCapture(network)

    override fun register(necto: NectoRegistrar) {
        network.register(necto)
    }
}

/**
 * Captures Ktor client traffic and reports it to whatever takes reports, on any engine.
 *
 * It only observes: the request's bytes go through unchanged and the response body reaches
 * the app as it arrives. Bytes are copied while they flow, up to
 * [NectoNetworkRecord.Body.CAPTURE_LIMIT], and the record completes when the response body
 * has been read to the end, so a streamed body is never held back. A streamed body the app
 * stops reading early ends its record with what arrived, or as failed, depending on the Ktor
 * version. A response from `HttpCache` completes without a body, and a body that Ktor's `SSE`
 * plugin turns into events is not captured.
 *
 * Each request the client sends is its own record, a redirect included. Install this after
 * a plugin that retries, such as `HttpRequestRetry`: installed before it, every attempt
 * shares one record, which shows the first answer rather than the last.
 *
 * Built against Ktor 3.0 and using only its public API, so a newer Ktor 3 in the app is fine.
 * On the OkHttp engine, use this or `NectoOkHttpInterceptor`, not both, or every request is
 * reported twice.
 */
@Suppress("FunctionName")
public fun NectoKtorCapture(reporter: NectoNetworkReporting): ClientPlugin<Unit> =
    createClientPlugin("NectoKtorCapture") {
        on(Send) { request ->
            val exchange = Exchange(reporter, request, this)
            request.attributes.put(ExchangeKey, exchange)
            exchange.started()
            val call = try {
                proceed(request)
            } catch (error: Throwable) {
                // Not only IOException: cancellation or a later plugin's exception would
                // otherwise leave the record pending forever.
                exchange.finished(error = error)
                throw error
            }
            // A response that never reached the engine, such as one HttpCache answers, skips
            // the receive pipeline and so the observer. It completes here, without a body.
            if (!exchange.observed) exchange.finished(call.response.status, call.response.headers)
            call
        }

        // Ktor's Logging installs the observer the same way: it reads a copy of the body
        // beside the app, and it is not registered under its own key, so the app can still
        // install ResponseObserver itself.
        ResponseObserver.install(
            ResponseObserver.prepare {
                // Runs inside the pipeline before `proceed` returns, unlike the handler.
                filter { call ->
                    call.attributes.getOrNull(ExchangeKey)?.observed = true
                    true
                }
                onResponse { response -> response.call.attributes.getOrNull(ExchangeKey)?.observe(response) }
            },
            client,
        )
    }

private val ExchangeKey = AttributeKey<Exchange>("NectoKtorCaptureExchange")

/** One request on its way out and back, reported once when it starts and once when it ends. */
private class Exchange(
    private val reporter: NectoNetworkReporting,
    request: HttpRequestBuilder,
    scope: CoroutineScope,
) {
    private val id = UUID.randomUUID().toString().uppercase()
    private val method = request.method.value
    private val url = request.url.buildString()
    private val startedAt = System.currentTimeMillis()
    private val startedNanos = System.nanoTime()
    private val done = AtomicBoolean(false)
    private val upload: Capture?

    /** Set once the response reaches the observer, which then reports the end. */
    @Volatile
    var observed: Boolean = false
    private val requestHeaders: Map<String, String>

    init {
        val content = request.body as? OutgoingContent
        upload = content?.let { Capture(it.contentType?.toString()) }
        if (content != null && upload != null) {
            request.setBody(observing(content, upload, scope), request.bodyType ?: typeInfo<OutgoingContent>())
        }
        requestHeaders = buildMap {
            putAll(flatten(request.headers.build()))
            content?.let { putAll(flatten(it.headers)) }
            content?.contentType?.let { putIfAbsent(HttpHeaders.ContentType, it.toString()) }
            content?.contentLength?.let { putIfAbsent(HttpHeaders.ContentLength, it.toString()) }
        }
    }

    fun started() = report(NectoNetworkRecord.State.PENDING)

    /** Reads the observer's copy of the body to the end, keeping the first bytes. */
    suspend fun observe(response: HttpResponse) {
        val capture = Capture(response.headers[HttpHeaders.ContentType])
        val error = try {
            copy(response.bodyAsChannel(), null, capture)
            null
        } catch (error: Throwable) {
            error
        }
        finished(response.status, response.headers, capture, error)
    }

    fun finished(
        status: HttpStatusCode? = null,
        headers: Headers? = null,
        body: Capture? = null,
        error: Throwable? = null,
    ) {
        if (!done.compareAndSet(false, true)) return
        report(
            if (error == null) NectoNetworkRecord.State.COMPLETED else NectoNetworkRecord.State.FAILED,
            status,
            headers,
            body,
            error,
        )
    }

    private fun report(
        state: NectoNetworkRecord.State,
        status: HttpStatusCode? = null,
        headers: Headers? = null,
        body: Capture? = null,
        error: Throwable? = null,
    ) {
        val pending = state == NectoNetworkRecord.State.PENDING
        val record = NectoNetworkRecord(
            id = id,
            method = method,
            url = url,
            startedAtMilliseconds = startedAt.toDouble(),
            state = state,
            statusCode = status?.value,
            durationMilliseconds = if (pending) null else (System.nanoTime() - startedNanos) / 1_000_000.0,
            responseByteCount = if (state == NectoNetworkRecord.State.COMPLETED) body?.count ?: 0 else null,
            errorSummary = error?.let { it.message ?: it.toString() },
            requestHeaders = requestHeaders,
            responseHeaders = headers?.let(::flatten).orEmpty(),
            // A pending record carries no body yet: sending it twice would double the
            // traffic for large uploads.
            requestBody = if (pending) null else upload?.body(),
            responseBody = body?.body(),
        )
        // Capture never breaks the request it observes.
        try {
            reporter.report(record)
        } catch (_: Exception) {
        }
    }
}

/**
 * Passes a request body through unchanged and copies the bytes as the engine takes them, up
 * to the capture limit. A body sent again, on a retry or a redirect, starts the copy over:
 * the last send is what went out.
 */
private fun observing(content: OutgoingContent, capture: Capture, scope: CoroutineScope): OutgoingContent =
    when (content) {
        is OutgoingContent.ByteArrayContent -> {
            val bytes = content.bytes()
            capture.add(bytes, bytes.size)
            content
        }
        is OutgoingContent.ReadChannelContent -> object : OutgoingContent.ReadChannelContent() {
            override val contentType get() = content.contentType
            override val contentLength get() = content.contentLength
            override val status get() = content.status
            override val headers get() = content.headers
            override fun <T : Any> getProperty(key: AttributeKey<T>): T? = content.getProperty(key)
            override fun <T : Any> setProperty(key: AttributeKey<T>, value: T?) = content.setProperty(key, value)
            override fun trailers(): Headers? = content.trailers()

            override fun readFrom(): ByteReadChannel {
                capture.reset()
                val source = content.readFrom()
                val out = ByteChannel()
                scope.launch {
                    try {
                        copy(source, out, capture)
                        out.flushAndClose()
                    } catch (error: Throwable) {
                        out.close(error)
                        // The engine gave up on the body: stop the app's producer as well, as
                        // it would stop had the engine read the channel itself.
                        source.cancel(error)
                    }
                }
                return out
            }
        }
        is OutgoingContent.WriteChannelContent -> object : OutgoingContent.WriteChannelContent() {
            override val contentType get() = content.contentType
            override val contentLength get() = content.contentLength
            override val status get() = content.status
            override val headers get() = content.headers
            override fun <T : Any> getProperty(key: AttributeKey<T>): T? = content.getProperty(key)
            override fun <T : Any> setProperty(key: AttributeKey<T>, value: T?) = content.setProperty(key, value)
            override fun trailers(): Headers? = content.trailers()

            override suspend fun writeTo(channel: ByteWriteChannel) {
                capture.reset()
                val pipe = ByteChannel()
                coroutineScope {
                    launch {
                        try {
                            content.writeTo(pipe)
                            pipe.flushAndClose()
                        } catch (error: Throwable) {
                            pipe.close(error)
                            throw error
                        }
                    }
                    copy(pipe, channel, capture)
                }
            }
        }
        is OutgoingContent.ContentWrapper -> content.copy(observing(content.delegate(), capture, scope))
        // Nothing to copy: no body, or a protocol upgrade that is no longer HTTP.
        else -> content
    }

/** Moves everything from [from] to [to], or discards it when [to] is null, copying the first bytes. */
private suspend fun copy(from: ByteReadChannel, to: ByteWriteChannel?, capture: Capture) {
    val buffer = ByteArray(8 * 1024)
    while (true) {
        val read = from.readAvailable(buffer, 0, buffer.size)
        if (read == -1) break
        if (read == 0) continue
        capture.add(buffer, read)
        if (to != null) {
            to.writeFully(buffer, 0, read)
            to.flush()
        }
    }
}

/** The first bytes of a body, up to the capture limit, and how many there were in all. */
private class Capture(private val contentType: String?) {
    private val kept = ByteArrayOutputStream()

    var count: Long = 0
        @Synchronized get
        private set

    @Synchronized
    fun add(bytes: ByteArray, length: Int) {
        val keep = minOf(length.toLong(), NectoNetworkRecord.Body.CAPTURE_LIMIT.toLong() - kept.size()).toInt()
        if (keep > 0) kept.write(bytes, 0, keep)
        count += length
    }

    @Synchronized
    fun reset() {
        kept.reset()
        count = 0
    }

    @Synchronized
    fun body(): NectoNetworkRecord.Body? {
        val bytes = kept.toByteArray()
        if (bytes.isEmpty()) return null
        return NectoNetworkRecord.Body.of(bytes, contentType, byteCount = count)
    }
}

private fun flatten(headers: Headers): Map<String, String> =
    headers.entries().associate { (name, values) -> name to values.joinToString(", ") }
