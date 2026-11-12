// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto

import im.toss.necto.transport.NectoListener
import im.toss.necto.transport.NectoMessageSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/** A loopback TCP listener on a port the OS picks, standing in for the Android socket. */
class LoopbackListener(private val frameTimeoutMillis: Long = NectoMessageSession.FRAME_TIMEOUT_MS) : NectoListener {
    private val server = ServerSocket().apply { bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0)) }

    override val endpoint: String = server.localPort.toString()

    override suspend fun accept(): NectoMessageSession = withContext(Dispatchers.IO) {
        val socket = try {
            server.accept()
        } catch (error: IOException) {
            throw IOException("The listener stopped", error)
        }
        session(socket, frameTimeoutMillis)
    }

    override fun stop() {
        runCatching { server.close() }
    }

    companion object {
        fun session(socket: Socket, frameTimeoutMillis: Long = NectoMessageSession.FRAME_TIMEOUT_MS): NectoMessageSession {
            socket.tcpNoDelay = true
            return NectoMessageSession(socket.getInputStream(), socket.getOutputStream(), {
                // Shutting down first wakes a read blocked on another thread.
                runCatching { socket.shutdownInput() }
                runCatching { socket.shutdownOutput() }
                runCatching { socket.close() }
            }, frameTimeoutMillis)
        }
    }
}
