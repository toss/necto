// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sdk

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class NectoSecurityTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val endpoint get() = File(context.noBackupFilesDir, "necto-endpoint")

    @Test fun appUidCannotReadHelloOrInvokeHandlers() {
        val sdk = NectoSDK(context, emptyList())
        sdk.start()
        try {
            assertEquals(384, Os.stat(endpoint.path).st_mode and 511)
            repeat(3) {
                LocalSocket().use { socket ->
                    socket.connect(LocalSocketAddress(endpoint.readText()))
                    socket.soTimeout = 2_000
                    assertEquals(-1, socket.inputStream.read())
                }
            }
        } finally { sdk.close() }
        assertFalse(endpoint.exists())
    }

    @Test fun restartRotatesEndpointAndOldCloseCannotDeleteNewEndpoint() {
        val first = NectoSDK(context, emptyList())
        first.start()
        val oldName = endpoint.readText()
        first.close()
        val second = NectoSDK(context, emptyList())
        second.start()
        try {
            val newName = endpoint.readText()
            assertNotEquals(oldName, newName)
            first.close()
            assertEquals(newName, endpoint.readText())
        } finally { second.close() }
    }

    @Test fun duplicateSdkCannotReplaceActiveEndpoint() {
        val first = NectoSDK(context, emptyList())
        first.start()
        val second = NectoSDK(context, emptyList())
        try {
            val before = endpoint.readText()
            assertNotNull(runCatching { second.start() }.exceptionOrNull())
            assertEquals(before, endpoint.readText())
        } finally {
            second.close()
            first.close()
        }
    }
}
