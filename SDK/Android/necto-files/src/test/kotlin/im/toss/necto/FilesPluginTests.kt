// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.decodeUtf8Head
import im.toss.necto.plugins.NectoFilesPlugin
import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import im.toss.necto.testing.PluginHarness

class FilesPluginTests {
    private val directory: File = Files.createTempDirectory("necto").toFile()
    private val files = PluginHarness(NectoFilesPlugin(listOf(NectoFilesPlugin.Root("files", "files", directory))))

    private fun input(vararg pairs: Pair<String, String>) = jsonObject(*pairs.map { it.first to jsonOf(it.second) }.toTypedArray())

    @Test
    fun filesListsPreviewsWritesAndDeletes() = runBlocking {
        File(directory, "logs").mkdirs()
        File(directory, "note.txt").writeText("hello")
        File(directory, "photo.png").writeBytes(byteArrayOf(1, 2, 3))
        File(directory, "blob.bin").writeBytes(byteArrayOf(0xC3.toByte(), 0x28))

        val entries = files.call("files.list", input("root" to "files"))["entries"]!!.arrayValue!!
        assertEquals(listOf("logs", "blob.bin", "note.txt", "photo.png"), entries.map { it["name"]!!.stringValue })
        assertEquals(jsonOf(0), entries[0]["itemCount"])

        val text = files.call("files.preview", input("root" to "files", "path" to "note.txt"))["file"]!!
        assertEquals(jsonOf("text"), text["kind"])
        assertEquals(jsonOf("hello"), text["text"])
        assertEquals(jsonOf(false), text["isTruncated"])

        val image = files.call("files.preview", input("root" to "files", "path" to "photo.png"))["file"]!!
        assertEquals(jsonOf("image/png"), image["mediaType"])
        assertEquals(jsonOf("AQID"), image["base64"])

        assertEquals(jsonOf("binary"), files.call("files.preview", input("root" to "files", "path" to "blob.bin"))["file"]!!["kind"])

        files.call("files.write", jsonObject("root" to jsonOf("files"), "path" to jsonOf("logs/new.txt"), "content" to jsonOf("é")))
        assertEquals("é", File(directory, "logs/new.txt").readText())

        files.call("files.delete", input("root" to "files", "path" to "logs"))
        assertFalse(File(directory, "logs").exists())
        Unit
    }

    @Test
    fun filesRefusesPathsOutsideTheRoot() = runBlocking {
        for (path in listOf("../etc/passwd", "/etc/passwd", "a/../../x")) {
            val error = assertFailsWith<NectoBridgeError> { files.call("files.info", input("root" to "files", "path" to path)) }
            assertEquals(NectoBridgeErrorCode.INVALID_INPUT, error.code)
        }
        assertFailsWith<NectoBridgeError> { files.call("files.delete", input("root" to "files", "path" to ".")) }
        assertFailsWith<NectoBridgeError> { files.call("files.list", input("root" to "other")) }
        assertTrue(directory.exists())
    }

    @Test
    fun deletingAFolderRemovesLinksWithoutEnteringThem() = runBlocking {
        val outside = Files.createTempDirectory("necto-outside").toFile()
        File(outside, "keep.txt").writeText("outside the root")
        val folder = File(directory, "cache").apply { mkdirs() }
        Files.createSymbolicLink(File(folder, "escape").toPath(), outside.toPath())
        Files.createSymbolicLink(File(folder, "escape.txt").toPath(), File(outside, "keep.txt").toPath())

        files.call("files.delete", input("root" to "files", "path" to "cache"))

        assertFalse(folder.exists())
        assertEquals("outside the root", File(outside, "keep.txt").readText())
        outside.deleteRecursively()
        Unit
    }

    @Test
    fun deletingALinkRemovesOnlyTheLink() = runBlocking {
        val target = File(directory, "keep").apply { mkdirs() }
        File(target, "target.txt").writeText("kept")
        val outside = Files.createTempDirectory("necto-outside").toFile()
        File(outside, "keep.txt").writeText("outside the root")
        Files.createSymbolicLink(File(directory, "alias").toPath(), target.toPath())
        Files.createSymbolicLink(File(directory, "escape").toPath(), outside.toPath())

        files.call("files.delete", input("root" to "files", "path" to "alias"))
        files.call("files.delete", input("root" to "files", "path" to "escape"))

        assertFalse(Files.exists(File(directory, "alias").toPath(), LinkOption.NOFOLLOW_LINKS))
        assertFalse(Files.exists(File(directory, "escape").toPath(), LinkOption.NOFOLLOW_LINKS))
        assertEquals("kept", File(target, "target.txt").readText())
        assertEquals("outside the root", File(outside, "keep.txt").readText())
        outside.deleteRecursively()
        Unit
    }

    @Test
    fun textPreviewSurvivesACutMultibyteCharacter() {
        val bytes = "가나".toByteArray()
        assertEquals("가", decodeUtf8Head(bytes.copyOf(4), isComplete = false))
        assertEquals(null, decodeUtf8Head(bytes.copyOf(4), isComplete = true))
    }

}
