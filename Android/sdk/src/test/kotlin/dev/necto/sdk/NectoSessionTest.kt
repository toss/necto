// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sdk

import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NectoSessionTest {
    private fun withSockets(body: (NectoSession, Socket) -> Unit) {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { listener ->
            Socket(InetAddress.getLoopbackAddress(), listener.localPort).use { client ->
                listener.accept().use { server ->
                    client.soTimeout = 3000
                    server.soTimeout = 3000
                    NectoSession(server.getInputStream(), server.getOutputStream(), server::close).use { body(it, client) }
                }
            }
        }
    }

    @Test fun readsFragmentedAndAdjacentUtf8Frames() = withSockets { session, client ->
        val output = DataOutputStream(client.getOutputStream())
        val bytes = "{\"text\":\"Android 연결\"}".toByteArray(Charsets.UTF_8)
        repeat(2) {
            output.writeInt(bytes.size)
            bytes.forEach { byte -> output.writeByte(byte.toInt()) }
        }
        repeat(2) { assertEquals("Android 연결", session.receive().getString("text")) }
    }

    @Test fun writesConcurrentFramesWithoutInterleaving() = withSockets { session, client ->
        runBlocking {
            val reader = async(Dispatchers.IO) {
                val input = DataInputStream(client.getInputStream())
                (0..<40).map {
                    val length = input.readInt()
                    assertTrue(length in 1..NectoSession.MAXIMUM_MESSAGE_BYTES)
                    val bytes = ByteArray(length)
                    input.readFully(bytes)
                    JSONObject(String(bytes, Charsets.UTF_8)).getInt("id")
                }.toSet()
            }
            (0..<40).map { id -> async(Dispatchers.IO) { session.send(JSONObject().put("id", id)) } }
                .forEach { it.await() }
            assertEquals((0..<40).toSet(), reader.await())
        }
    }

    @Test fun rejectsOversizedOrNegativeLengthsBeforeAllocation() {
        for (length in listOf(-1, NectoSession.MAXIMUM_REQUEST_BYTES + 1)) {
            withSockets { session, client ->
                DataOutputStream(client.getOutputStream()).writeInt(length)
                val error = runCatching { session.receive() }.exceptionOrNull()
                assertTrue(error is IllegalArgumentException)
            }
        }
    }
    @Test fun rejectsDeepJsonAndInvalidUtf8() {
        val deep = ("{\"value\":" + "[".repeat(65) + "0" + "]".repeat(65) + "}").toByteArray()
        val invalid = byteArrayOf(123, 34, 120, 34, 58, 34, -1, 34, 125)
        for (bytes in listOf(deep, invalid)) {
            withSockets { session, client ->
                DataOutputStream(client.getOutputStream()).also { it.writeInt(bytes.size); it.write(bytes) }
                assertTrue(runCatching { session.receive() }.isFailure)
            }
        }
    }

    @Test fun partialFrameHasAnAbsoluteDeadline() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { listener ->
            Socket(InetAddress.getLoopbackAddress(), listener.localPort).use { client ->
                listener.accept().use { server ->
                    server.soTimeout = 3000
                    NectoSession(server.getInputStream(), server.getOutputStream(), server::close, 50).use { session ->
                        client.getOutputStream().write(0)
                        val start = System.nanoTime()
                        assertTrue(runCatching { session.receive() }.isFailure)
                        assertTrue((System.nanoTime() - start) / 1_000_000 < 2000)
                    }
                }
            }
        }
    }

}
