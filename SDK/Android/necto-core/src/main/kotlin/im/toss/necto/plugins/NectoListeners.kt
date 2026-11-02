// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import im.toss.necto.model.NectoJsonValue
import im.toss.necto.sdk.NectoOut
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext

/**
 * The open subscriptions of one stream operation. A subscription lasts for as long as
 * the caller listens; [broadcast] reaches every one of them, in order. A reader that
 * falls far behind loses the oldest updates rather than growing memory without bound.
 */
internal class NectoListeners(private val buffer: Int = 1024) {
    private val lock = Any()
    private val channels = LinkedHashSet<Channel<NectoJsonValue>>()

    val isEmpty: Boolean get() = synchronized(lock) { channels.isEmpty() }

    /** Suspends until cancelled, which is how the bridge ends a subscription. */
    suspend fun hold(out: NectoOut, onStart: suspend () -> Unit = {}, onEnd: suspend () -> Unit = {}) {
        val channel = Channel<NectoJsonValue>(buffer, BufferOverflow.DROP_OLDEST)
        synchronized(lock) { channels.add(channel) }
        try {
            onStart()
            for (value in channel) out.send(value)
        } finally {
            synchronized(lock) { channels.remove(channel) }
            channel.close()
            withContext(NonCancellable) { onEnd() }
        }
    }

    fun broadcast(value: NectoJsonValue) {
        val targets = synchronized(lock) { channels.toList() }
        for (channel in targets) channel.trySend(value)
    }
}
