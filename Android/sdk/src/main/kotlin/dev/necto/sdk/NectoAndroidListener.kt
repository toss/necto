// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sdk

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import java.io.File
import java.io.RandomAccessFile
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean

internal class NectoAndroidListener(context: Context) : AutoCloseable {
    private val closed = AtomicBoolean()
    private val endpoint = File(context.noBackupFilesDir, "necto-endpoint")
    private val lockFile = RandomAccessFile(File(context.noBackupFilesDir, "necto-lock"), "rw")
    private val lock = try {
        checkNotNull(lockFile.channel.tryLock()) { "Necto is already running in this app" }
    } catch (error: Exception) {
        lockFile.close()
        throw error
    }
    private val server: LocalServerSocket

    init {
        var created: LocalServerSocket? = null
        try {
            // A fresh, unguessable name prevents another app from pre-binding our endpoint.
            val random = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val name = "necto." + random.joinToString("") { "%02x".format(it) }
            created = LocalServerSocket(name)
            val file = AtomicFile(endpoint)
            val output = file.startWrite()
            try {
                Os.fchmod(output.fd, 384) // 0600; the endpoint stays in private app storage.
                output.write(name.toByteArray(Charsets.UTF_8))
                file.finishWrite(output)
            } catch (error: Exception) {
                file.failWrite(output)
                throw error
            }
            server = created
        } catch (error: Exception) {
            created?.close()
            lock.release()
            lockFile.close()
            throw error
        }
    }

    fun accept(): LocalSocket {
        while (true) {
            val socket = server.accept()
            try {
                // adbd runs as shell on user builds and root on some development images.
                if (socket.peerCredentials.uid in setOf(0, 2000)) return socket
            } catch (_: Exception) {
                socket.close()
                continue
            }
            socket.close()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { Os.shutdown(server.fileDescriptor, OsConstants.SHUT_RDWR) }
        runCatching { server.close() }
        endpoint.delete()
        runCatching { lock.release() }
        runCatching { lockFile.close() }
    }
}

// close() alone does not reliably wake a read blocked on a LocalSocket.
internal fun LocalSocket.disconnect() {
    runCatching { shutdownInput() }
    runCatching { shutdownOutput() }
    runCatching { close() }
}
