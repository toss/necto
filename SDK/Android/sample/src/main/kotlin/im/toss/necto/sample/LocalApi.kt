// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * A tiny REST server inside the app, so the traffic demo needs no internet.
 *
 * The network plugin captures requests as the OkHttp interceptor sees them, which
 * happens long before anything reaches a network. Pointing the demo at a public API
 * only added ways for it to fail: a corporate connection that inspects TLS, an offline
 * device, a rate limit, a service that went away. Answering locally removes all of
 * them, and lets each route produce exactly the status, delay and size it is meant to
 * demonstrate.
 */
object LocalApi {
    private val lock = Any()
    private var server: ServerSocket? = null

    /** The origin to send demo requests to, once [start] has bound a port. */
    val origin: String get() = "http://127.0.0.1:${synchronized(lock) { server?.localPort ?: 0 }}"

    fun start() {
        val socket = synchronized(lock) {
            if (server != null) return
            // Port 0 asks the OS for a free one, so the demo never collides with whatever
            // else the device is running, Necto's own listener included. Loopback only:
            // nothing outside the device can reach it.
            runCatching { ServerSocket(0, 8, InetAddress.getByName("127.0.0.1")) }.getOrNull()
                ?.also { server = it } ?: return
        }

        // Blocking accept, so it gets a thread rather than a coroutine.
        thread(name = "necto.example.api", isDaemon = true) {
            while (true) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                thread(isDaemon = true) { client.use(::answer) }
            }
        }
    }

    // MARK: Routing

    private fun answer(client: Socket) {
        val input = BufferedInputStream(client.getInputStream())
        val head = readHead(input) ?: return
        val lines = head.split("\r\n")
        val path = lines.first().split(" ").getOrNull(1) ?: "/"

        // Read the body even though no route uses it: closing a socket with unread bytes
        // resets the connection, and the client would see that instead of the answer.
        val length = lines.drop(1)
            .firstOrNull { it.startsWith("Content-Length:", ignoreCase = true) }
            ?.substringAfter(':')?.trim()?.toIntOrNull() ?: 0
        repeat(length) { if (input.read() < 0) return@repeat }

        val (status, body) = route(path)
        send(status, body, client)
    }

    private fun readHead(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        var matched = 0
        val end = "\r\n\r\n"
        while (matched < end.length) {
            val byte = input.read()
            if (byte < 0) return null
            buffer.write(byte)
            matched = if (byte.toChar() == end[matched]) matched + 1 else if (byte.toChar() == end[0]) 1 else 0
            if (buffer.size() > 64 * 1024) return null
        }
        return buffer.toString(Charsets.UTF_8.name())
    }

    private fun route(path: String): Pair<Int, String> = when {
        path.startsWith("/posts/999") -> 404 to """{"error":"No post with that id"}"""
        path.startsWith("/posts/") -> 200 to post(1)
        path.startsWith("/posts") -> 200 to "[${(1..10).joinToString(",") { post(it) }}]"
        path == "/session" -> 204 to ""
        // Stands in for a company encrypt service: field values in, ticket out.
        path == "/encrypt" -> 200 to """{"payload":"ticket-ok"}"""
        path == "/error" -> 500 to """{"error":"Something went wrong on the server"}"""
        path == "/slow" -> {
            // Long enough to stand out beside the fast rows in the plugin.
            Thread.sleep(2000)
            200 to """{"slept":"2s"}"""
        }
        path == "/large" -> {
            // Past the plugin's capture limit, so truncation is demonstrated.
            val items = (1..4000).joinToString(",") { """{"id":$it,"label":"row $it","note":"a line of text to make this large"}""" }
            200 to """{"items":[$items]}"""
        }
        else -> 404 to """{"error":"No such route"}"""
    }

    private fun post(id: Int): String = """{"id":$id,"userId":1,"title":"Post $id","body":"Written by Necto Example."}"""

    private fun send(status: Int, body: String, client: Socket) {
        val reason = mapOf(200 to "OK", 201 to "Created", 204 to "No Content", 404 to "Not Found", 500 to "Internal Server Error")
        val payload = body.toByteArray(Charsets.UTF_8)
        val head = "HTTP/1.1 $status ${reason[status] ?: "OK"}\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: ${payload.size}\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        val out = client.getOutputStream()
        out.write(head.toByteArray(Charsets.UTF_8))
        out.write(payload)
        out.flush()
    }
}
