// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import im.toss.necto.transport.NectoListener
import im.toss.necto.transport.NectoMessageSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Waits for Necto on a Unix socket in the abstract namespace, which only ADB reaches.
 *
 * The name is random each time, so no other app can bind it first, and it is written to
 * the app's private storage, where only `adb shell run-as` can read it. The host learns
 * it that way and runs `adb forward localfilesystem:… localabstract:<name>`. Any app can
 * still connect to an abstract socket it knows the name of, so a connection is only
 * accepted from adbd, which runs as shell, or as root on some development images.
 *
 * Constructing one binds the socket; [stop] releases it.
 */
internal class NectoAndroidListener(context: Context) : NectoListener {
    private val closed = AtomicBoolean()
    private val directory = context.noBackupFilesDir
    private val endpointFile = File(directory, ENDPOINT_FILE)
    private val lockFile = RandomAccessFile(File(directory, LOCK_FILE), "rw")
    private val lock: FileLock = try {
        // A second process of the same app would otherwise overwrite the endpoint.
        lockFile.channel.tryLock() ?: throw IOException("Necto is already running in another process of this app")
    } catch (error: Exception) {
        lockFile.close()
        throw error
    }
    private val server: LocalServerSocket

    override val endpoint: String

    init {
        var created: LocalServerSocket? = null
        try {
            val random = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val name = "necto." + random.joinToString("") { "%02x".format(it) }
            created = LocalServerSocket(name)
            writeEndpoint(name)
            endpoint = name
            server = created
        } catch (error: Exception) {
            created?.close()
            runCatching { lock.release() }
            lockFile.close()
            throw error
        }
    }

    /** Written whole or not at all, and readable by this app alone. */
    private fun writeEndpoint(name: String) {
        val file = AtomicFile(endpointFile)
        val output = file.startWrite()
        try {
            Os.fchmod(output.fd, PRIVATE_MODE)
            output.write(name.toByteArray(Charsets.UTF_8))
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    override suspend fun accept(): NectoMessageSession = withContext(Dispatchers.IO) {
        val socket = acceptFromAdb()
        NectoMessageSession(socket.inputStream, socket.outputStream, { socket.disconnect() })
    }

    private fun acceptFromAdb(): LocalSocket {
        while (true) {
            if (closed.get()) throw IOException("The listener stopped")
            val socket = server.accept()
            val uid = runCatching { socket.peerCredentials.uid }.getOrNull()
            if (uid in ADB_UIDS) return socket
            socket.disconnect()
        }
    }

    override fun stop() {
        if (!closed.compareAndSet(false, true)) return
        // close() alone does not wake a thread blocked in accept().
        runCatching { Os.shutdown(server.fileDescriptor, OsConstants.SHUT_RDWR) }
        runCatching { server.close() }
        endpointFile.delete()
        runCatching { lock.release() }
        runCatching { lockFile.close() }
    }

    private companion object {
        const val ENDPOINT_FILE = "necto-endpoint"
        const val LOCK_FILE = "necto-lock"

        /** 0600. */
        const val PRIVATE_MODE = 384

        /** root and shell, which adbd runs as. */
        val ADB_UIDS = setOf(0, 2000)
    }
}

// close() alone does not reliably wake a read blocked on a LocalSocket.
private fun LocalSocket.disconnect() {
    runCatching { shutdownInput() }
    runCatching { shutdownOutput() }
    runCatching { close() }
}
