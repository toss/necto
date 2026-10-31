// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonArray
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import java.util.Base64

/**
 * The app's own storage, read from Necto. Register it and it answers: the files are
 * already there. On Android, `NectoAndroidPlugins.files(context)` supplies the standard
 * roots (files, cache, the data directory and external files).
 */
public class NectoFilesPlugin(private val roots: List<Root>) : NectoPlugin {
    /** One place a panel may look. A path is only ever resolved inside one of them. */
    public data class Root(val id: String, val name: String, val directory: File)

    override val id: String = "files"

    override val panel: NectoPluginPanel = NectoPanels.resource("files")

    override fun register(necto: NectoRegistrar) {
        necto.handle("files.roots") {
            jsonObject(
                "roots" to jsonArray(roots.map { root ->
                    jsonObject(
                        "id" to jsonOf(root.id),
                        "name" to jsonOf(root.name),
                        "path" to jsonOf(root.directory.path),
                    )
                }),
            )
        }

        necto.handle("files.list") { input ->
            val directory = resolve(input)
            val children = directory.listFiles()
                ?: throw NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "'${directory.name}' cannot be listed")
            // Directories first, then by name: the shape a person expects a file browser to have.
            val entries = children
                .sortedWith(compareBy<File>({ !it.isDirectory }, { it.name }))
                .map(::entry)
            jsonObject("entries" to jsonArray(entries))
        }

        necto.handle("files.preview") { input ->
            val file = resolve(input, requirePath = true)
            if (file.isDirectory) throw invalid("'${file.name}' is a directory")
            if (!file.exists()) throw NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "'${file.name}' does not exist")

            val size = file.length()
            val fields = linkedMapOf(
                "name" to jsonOf(file.name),
                "size" to jsonOf(size),
            )
            if (file.lastModified() > 0) fields["modifiedAt"] = jsonOf(file.lastModified())

            // An image is the one binary a panel can actually show.
            val mediaType = imageMediaType(file)
            if (mediaType != null && size <= IMAGE_LIMIT) {
                fields["kind"] = jsonOf("image")
                fields["mediaType"] = jsonOf(mediaType)
                fields["base64"] = jsonOf(Base64.getEncoder().encodeToString(file.readBytes()))
                return@handle jsonObject("file" to jsonObject(fields))
            }

            // Read only the head: the point is recognition, and a log file can be huge.
            val head = file.inputStream().use { stream ->
                val buffer = ByteArray(PREVIEW_LIMIT)
                var read = 0
                while (read < buffer.size) {
                    val count = stream.read(buffer, read, buffer.size - read)
                    if (count < 0) break
                    read += count
                }
                buffer.copyOf(read)
            }
            val text = decodeUtf8Head(head, isComplete = head.size.toLong() >= size)
            if (text != null) {
                fields["kind"] = jsonOf("text")
                fields["text"] = jsonOf(text)
                fields["isTruncated"] = jsonOf(size > head.size)
            } else {
                fields["kind"] = jsonOf("binary")
            }
            jsonObject("file" to jsonObject(fields))
        }

        necto.handle("files.info") { input ->
            val target = resolve(input, requirePath = true)
            if (!target.exists()) throw NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "'${target.name}' does not exist")
            jsonObject("item" to entry(target))
        }

        necto.handle("files.write") { input ->
            val target = resolve(input, requirePath = true)
            val content = input["content"]?.stringValue ?: throw invalid("content is required")
            if (target.isDirectory) throw invalid("'${target.name}' is a directory")
            val data = content.toByteArray(Charsets.UTF_8)
            // Written beside the target and moved over it, so a reader never sees half a file.
            val temporary = File(target.parentFile, ".${target.name}.necto-${System.nanoTime()}")
            try {
                temporary.writeBytes(data)
                if (!temporary.renameTo(target)) {
                    target.writeBytes(data)
                }
            } finally {
                temporary.delete()
            }
            jsonObject("written" to jsonOf(true), "size" to jsonOf(data.size))
        }

        necto.handle("files.delete") { input ->
            val target = resolveEntry(input)
            if (roots.any { it.directory.canonicalFile == target }) throw invalid("A root cannot be deleted")
            if (!Files.exists(target.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                throw NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "'${target.name}' does not exist")
            }
            deleteWithoutFollowingLinks(target.toPath())
            jsonObject("removed" to jsonOf(true))
        }
    }

    /**
     * Deletes [path] and everything under it. A symlink inside is removed as a link: its
     * target, which may lie outside the root, is never entered.
     */
    private fun deleteWithoutFollowingLinks(path: Path) {
        Files.walkFileTree(path, object : SimpleFileVisitor<Path>() {
            override fun visitFile(file: Path, attributes: BasicFileAttributes): FileVisitResult {
                Files.delete(file)
                return FileVisitResult.CONTINUE
            }

            override fun postVisitDirectory(directory: Path, error: IOException?): FileVisitResult {
                if (error != null) throw error
                Files.delete(directory)
                return FileVisitResult.CONTINUE
            }
        })
    }

    /**
     * The root and path from an input, resolved to a file that is provably inside the
     * root. A path that escapes (`..`, absolute, a symlink out) is refused.
     */
    private fun resolve(input: NectoJsonValue, requirePath: Boolean = false): File {
        val rootID = input["root"]?.stringValue
        val root = roots.firstOrNull { it.id == rootID } ?: throw invalid("This app does not offer that root")
        val path = input["path"]?.stringValue ?: ""
        if (requirePath && path.isEmpty()) throw invalid("path is required")
        if (path.startsWith("/")) throw invalid("path must be relative to the root")

        val base = root.directory.canonicalFile
        val resolved = if (path.isEmpty()) base else File(base, path).canonicalFile
        if (resolved != base && !resolved.path.startsWith(base.path + File.separator)) {
            throw invalid("path escapes the root")
        }
        return resolved
    }

    /**
     * Like [resolve], but the last part of the path is the entry itself: a symlink there
     * is the link, not what it points to. Its folder must still be inside the root.
     */
    private fun resolveEntry(input: NectoJsonValue): File {
        val path = (input["path"]?.stringValue ?: "").trimEnd('/')
        val name = path.substringAfterLast('/')
        if (name.isEmpty() || name == "." || name == "..") return resolve(input, requirePath = true)
        val folder = resolve(input.withPath(path.substringBeforeLast('/', "")))
        return File(folder, name)
    }

    private fun NectoJsonValue.withPath(path: String): NectoJsonValue =
        jsonObject("root" to (this["root"] ?: NectoJsonValue.Null), "path" to jsonOf(path))

    private fun invalid(message: String) = NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, message)

    public companion object {
        /** Enough of a text file to recognise it by. */
        public const val PREVIEW_LIMIT: Int = 32 * 1024

        /** An image is read whole or not at all. */
        public const val IMAGE_LIMIT: Long = 8L * 1024 * 1024

        /** The image types a panel can render, by extension. Nothing is sniffed from the bytes. */
        public val IMAGE_MEDIA_TYPES: Map<String, String> = mapOf(
            "png" to "image/png",
            "jpg" to "image/jpeg",
            "jpeg" to "image/jpeg",
            "gif" to "image/gif",
            "heic" to "image/heic",
            "heif" to "image/heic",
            "bmp" to "image/bmp",
            "tif" to "image/tiff",
            "tiff" to "image/tiff",
            "webp" to "image/webp",
        )

        internal fun imageMediaType(file: File): String? = IMAGE_MEDIA_TYPES[file.extension.lowercase()]

        /**
         * UTF-8 text, or null when the bytes are not UTF-8. A head cut mid-character is
         * still text, so up to three trailing bytes of an incomplete sequence are dropped.
         */
        internal fun decodeUtf8Head(bytes: ByteArray, isComplete: Boolean): String? {
            val attempts = if (isComplete) 0..0 else 0..minOf(3, bytes.size)
            for (drop in attempts) {
                try {
                    return Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes, 0, bytes.size - drop)).toString()
                } catch (_: CharacterCodingException) {
                }
            }
            return null
        }

        internal fun entry(file: File): NectoJsonValue {
            val fields = linkedMapOf(
                "name" to jsonOf(file.name),
                "isDirectory" to jsonOf(file.isDirectory),
            )
            if (file.isDirectory) {
                // Shallow, and only the count: sizing a tree costs a walk of it.
                fields["itemCount"] = jsonOf(file.list()?.size ?: 0)
            } else {
                fields["size"] = jsonOf(file.length())
            }
            if (file.lastModified() > 0) fields["modifiedAt"] = jsonOf(file.lastModified())
            runCatching { Files.readAttributes(file.toPath(), BasicFileAttributes::class.java).creationTime().toMillis() }
                .getOrNull()
                ?.takeIf { it > 0 }
                ?.let { fields["createdAt"] = jsonOf(it) }
            return jsonObject(fields)
        }
    }
}
