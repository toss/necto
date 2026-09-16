// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sdk

import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject
import org.json.JSONTokener

internal class NectoSession(
    input: InputStream,
    output: OutputStream,
    private val closeConnection: () -> Unit,
    private val frameTimeoutMillis: Long = 10_000,
) : AutoCloseable {
    private val input = DataInputStream(input)
    private val output = DataOutputStream(output)
    private val closed = AtomicBoolean()
    private val writeLock = Mutex()

    fun receive(maximumBytes: Int = MAXIMUM_REQUEST_BYTES): JSONObject {
        // Quiet streams may remain connected; once a frame starts it has a fixed deadline.
        val first = input.readUnsignedByte()
        return boundedIO {
            val length = (first shl 24) or (input.readUnsignedByte() shl 16) or
                (input.readUnsignedByte() shl 8) or input.readUnsignedByte()
            require(length in 1..maximumBytes) { "Invalid frame length: $length" }
            val bytes = ByteArray(length)
            input.readFully(bytes)
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
            val tokens = BoundedJSONTokener(text)
            JSONObject(tokens).also { require(tokens.nextClean() == '\u0000') { "Trailing JSON content" } }
        }
    }

    suspend fun send(value: JSONObject) {
        currentCoroutineContext().ensureActive()
        val bytes = value.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAXIMUM_MESSAGE_BYTES) { "Message exceeds frame limit" }
        writeLock.withLock {
            currentCoroutineContext().ensureActive()
            boundedIO {
                output.writeInt(bytes.size)
                output.write(bytes)
                output.flush()
            }
        }
    }

    private fun <T> boundedIO(body: () -> T): T {
        val timeout = closeAfter(frameTimeoutMillis)
        return try { body() } finally { timeout.cancel(false) }
    }

    fun closeAfter(milliseconds: Long) = deadlines.schedule({ close() }, milliseconds, TimeUnit.MILLISECONDS)

    override fun close() {
        if (closed.compareAndSet(false, true)) closeConnection()
    }

    companion object {
        const val MAXIMUM_REQUEST_BYTES = 64 * 1024
        const val MAXIMUM_MESSAGE_BYTES = 32 * 1024 * 1024
        private val deadlines = ScheduledThreadPoolExecutor(1) { runnable ->
            Thread(runnable, "Necto I/O deadlines").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }
    }
}

private class BoundedJSONTokener(text: String) : JSONTokener(text) {
    private var depth = 0

    override fun nextValue(): Any {
        require(depth++ < 64) { "JSON nesting exceeds the limit" }
        return try { super.nextValue() } finally { depth-- }
    }
}
