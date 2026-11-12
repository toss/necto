// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto

import im.toss.necto.plugins.NectoNetworkRecord
import im.toss.necto.plugins.NectoNetworkRecordCoding
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NetworkPluginTests {
    private val directory: File = Files.createTempDirectory("necto").toFile()

    @Test
    fun curlQuotesEveryPartTheAppSupplied() {
        val marker = File(directory, "ran")
        val injected = "'; touch ${marker.path}; '"
        val record = NectoNetworkRecord(
            "r", "GET$injected", "https://example.com/a$injected", 1.0, NectoNetworkRecord.State.COMPLETED,
            requestHeaders = mapOf("X-Name$injected" to "v$injected"),
        )
        val command = NectoNetworkRecordCoding.curl(record).replaceFirst("curl", "printf '%s\\n'")
        val process = ProcessBuilder("sh", "-c", command).redirectErrorStream(true).start()
        val arguments = process.inputStream.bufferedReader().readLines()
        assertEquals(0, process.waitFor())

        assertFalse(marker.exists())
        assertEquals(
            listOf("-X", "GET$injected", "https://example.com/a$injected", "-H", "X-Name$injected: v$injected"),
            arguments,
        )
    }

    @Test
    fun aCutBodyKeepsItsTextPrefix() {
        val limit = NectoNetworkRecord.Body.CAPTURE_LIMIT
        val data = ("a".repeat(limit - 1) + "가나").toByteArray()
        val body = NectoNetworkRecord.Body.of(data, "application/json")
        assertTrue(body.isTruncated)
        assertEquals("a".repeat(limit - 1), body.text)
        assertEquals(null, NectoNetworkRecord.Body.of(byteArrayOf(0xC3.toByte()), "text/plain").text)
    }

}
