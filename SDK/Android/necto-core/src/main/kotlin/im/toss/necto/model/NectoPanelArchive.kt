// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64

/**
 * A panel's files, in the one shape they travel: a flat list of relative paths and
 * bytes. Kept in canonical order so equality and hashing never depend on how a file
 * system chose to enumerate.
 */
public class NectoPanelArchive(files: List<File>) {
    public class File(public val path: String, public val data: ByteArray) {
        override fun equals(other: Any?): Boolean = other is File && path == other.path && data.contentEquals(other.data)
        override fun hashCode(): Int = 31 * path.hashCode() + data.contentHashCode()
    }

    public val files: List<File> = files.sortedWith(compareBy(UTF16_ORDER) { it.path })

    /** The identity of these exact bytes at these exact paths. */
    public val contentHash: String
        get() {
            val digest = MessageDigest.getInstance("SHA-256")
            fun appendLength(length: Int) = digest.update(ByteBuffer.allocate(8).putLong(length.toLong()).array())
            appendLength(files.size)
            for (file in files) {
                val path = file.path.toByteArray(Charsets.UTF_8)
                appendLength(path.size)
                digest.update(path)
                appendLength(file.data.size)
                digest.update(file.data)
            }
            return digest.digest().toHex()
        }

    /** Compatibility with older hosts. Never use for approvals or cache reuse. */
    public val legacyContentHash: String
        get() {
            val digest = MessageDigest.getInstance("SHA-256")
            for (file in files) {
                digest.update(file.path.toByteArray(Charsets.UTF_8))
                digest.update(0)
                digest.update(file.data)
                digest.update(0)
            }
            return digest.digest().toHex()
        }

    public val stamp: NectoPanelStamp get() = NectoPanelStamp(hash = legacyContentHash, contentHash = contentHash)

    /** As it travels in a plugin result: `{"files": [{"path": …, "data": base64}]}`. */
    public fun toJson(): NectoJsonValue = jsonObject(
        "files" to jsonArray(files.map { file ->
            jsonObject(
                "path" to jsonOf(file.path),
                "data" to jsonOf(Base64.getEncoder().encodeToString(file.data)),
            )
        }),
    )

    override fun equals(other: Any?): Boolean = other is NectoPanelArchive && files == other.files
    override fun hashCode(): Int = files.hashCode()

    public companion object {
        /**
         * Swift orders `String` by Unicode scalars, which for the ASCII paths panels use
         * is the same as Kotlin's natural order. Named so the intent is visible.
         */
        private val UTF16_ORDER: Comparator<String> = naturalOrder()

        private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

        public fun fromJson(json: NectoJsonValue): NectoPanelArchive {
            val rows = json["files"]?.arrayValue ?: throw NectoJsonException("The panel archive has no files array")
            return NectoPanelArchive(rows.map { row ->
                val path = row["path"]?.stringValue
                val data = row["data"]?.stringValue?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
                if (path == null || data == null) throw NectoJsonException("A file row is missing path or data")
                File(path, data)
            })
        }

        /**
         * Collects every regular file under [directory]. Hidden files stay out: a
         * `.DS_Store` must never change what a panel is. Symlinks are refused.
         */
        public fun read(directory: java.io.File): NectoPanelArchive {
            val base = directory.canonicalFile
            if (!base.isDirectory) throw IllegalArgumentException("Could not enumerate '${directory.path}'")
            val files = ArrayList<File>()
            fun walk(current: java.io.File) {
                val children = current.listFiles() ?: throw IllegalArgumentException("Could not enumerate '${current.path}'")
                for (child in children) {
                    if (child.name.startsWith(".")) continue
                    if (java.nio.file.Files.isSymbolicLink(child.toPath())) {
                        throw IllegalArgumentException("'${child.path}' does not stay inside the panel")
                    }
                    when {
                        child.isDirectory -> walk(child)
                        child.isFile -> files.add(File(child.relativeTo(base).invariantSeparatorsPath, child.readBytes()))
                    }
                }
            }
            walk(base)
            return NectoPanelArchive(files)
        }
    }
}
