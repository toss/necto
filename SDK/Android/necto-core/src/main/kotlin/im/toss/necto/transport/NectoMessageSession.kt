// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.transport

import im.toss.necto.model.NectoJsonValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A message oriented session over a byte stream: each message is framed as a 4 byte
 * big endian length followed by the payload, exactly like the Swift transport.
 *
 * The peer is not trusted to be well behaved. A quiet stream may stay open, but once a
 * frame starts it must arrive within [frameTimeoutMillis], as must every write; past
 * that the session closes. Inbound frames are bounded by the `maximumBytes` the caller
 * passes, which is far smaller than what the app may send.
 */
public class NectoMessageSession(
    input: InputStream,
    output: OutputStream,
    private val onClose: () -> Unit = {},
    private val frameTimeoutMillis: Long = FRAME_TIMEOUT_MS,
) {
    public class MessageTooLargeException(size: Long) : IOException("Message of $size bytes exceeds the frame limit")

    private val input = DataInputStream(input)
    private val output = BufferedOutputStream(output)
    private val writeLock = Any()
    private val receiving = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    public val isClosed: Boolean get() = closed.get()

    /** Closes the stream, waking any pending read. Idempotent. */
    public fun close() {
        if (closed.compareAndSet(false, true)) onClose()
    }

    /** Sends one frame. Writes from several coroutines never interleave. */
    public suspend fun send(message: ByteArray): Unit = withContext(Dispatchers.IO) {
        if (message.size > MAXIMUM_MESSAGE_BYTES) throw MessageTooLargeException(message.size.toLong())
        synchronized(writeLock) {
            if (closed.get()) throw IOException("The connection closed")
            try {
                bounded {
                    val size = message.size
                    output.write(byteArrayOf((size ushr 24).toByte(), (size ushr 16).toByte(), (size ushr 8).toByte(), size.toByte()))
                    output.write(message)
                    output.flush()
                }
            } catch (error: IOException) {
                close()
                throw error
            }
        }
    }

    /**
     * Reads one frame of 1 to [maximumBytes] bytes. Anything else closes the session: an
     * empty frame carries no message, and a longer one is not worth the memory.
     */
    public suspend fun receive(maximumBytes: Int = MAXIMUM_INBOUND_BYTES): ByteArray = withContext(Dispatchers.IO) {
        check(receiving.compareAndSet(false, true)) { "Only one receiver may read a session at a time" }
        try {
            // Waiting for a frame to start has no deadline; reading the rest of it does.
            val first = input.readUnsignedByte()
            bounded {
                val length = (first.toLong() shl 24) or
                    (input.readUnsignedByte().toLong() shl 16) or
                    (input.readUnsignedByte().toLong() shl 8) or
                    input.readUnsignedByte().toLong()
                if (length !in 1..maximumBytes.toLong()) {
                    close()
                    throw MessageTooLargeException(length)
                }
                ByteArray(length.toInt()).also { input.readFully(it) }
            }
        } catch (error: EOFException) {
            close()
            throw IOException("The connection closed", error)
        } catch (error: IOException) {
            close()
            throw error
        } finally {
            receiving.set(false)
        }
    }

    public suspend fun send(value: NectoJsonValue): Unit = send(value.toJson().toByteArray(Charsets.UTF_8))

    /** Reads one frame as JSON. Malformed UTF-8 is refused rather than replaced. */
    public suspend fun receiveJson(maximumBytes: Int = MAXIMUM_INBOUND_BYTES): NectoJsonValue {
        val bytes = receive(maximumBytes)
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (error: CharacterCodingException) {
            throw IOException("The message is not valid UTF-8", error)
        }
        return NectoJsonValue.parse(text)
    }

    /** Closes the session after [milliseconds] unless the returned handle is cancelled first. */
    public fun closeAfter(milliseconds: Long): Deadline {
        val future = deadlines.schedule({ close() }, milliseconds, TimeUnit.MILLISECONDS)
        return Deadline { future.cancel(false) }
    }

    public fun interface Deadline {
        public fun cancel()
    }

    // A blocked stream ignores coroutine cancellation, so the deadline closes the
    // session instead, which fails the read or write in progress.
    private inline fun <T> bounded(body: () -> T): T {
        val deadline = closeAfter(frameTimeoutMillis)
        try {
            return body()
        } finally {
            deadline.cancel()
        }
    }

    public companion object {
        /** The most the app accepts in one frame. Requests are small; answers are not. */
        public const val MAXIMUM_INBOUND_BYTES: Int = 64 * 1024

        /** The most the app sends in one frame, the same limit the host reads with. */
        public const val MAXIMUM_MESSAGE_BYTES: Int = 32 * 1024 * 1024

        /** How long a started frame, or a write, may take. */
        public const val FRAME_TIMEOUT_MS: Long = 10_000

        private val deadlines = ScheduledThreadPoolExecutor(1) { runnable ->
            Thread(runnable, "Necto I/O deadlines").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }
    }
}
