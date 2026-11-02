// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import java.net.URI

/** Somewhere to report a request to. */
public interface NectoNetworkReporting {
    public fun report(record: NectoNetworkRecord)
}

/**
 * One network request observed inside the app. Sent twice, once when the request
 * starts and once when it finishes; the [id] ties them together.
 */
public data class NectoNetworkRecord(
    val id: String,
    val method: String,
    val url: String,
    val startedAtMilliseconds: Double,
    val state: State,
    val statusCode: Int? = null,
    val durationMilliseconds: Double? = null,
    val responseByteCount: Long? = null,
    val errorSummary: String? = null,
    val requestHeaders: Map<String, String> = emptyMap(),
    val responseHeaders: Map<String, String> = emptyMap(),
    val requestBody: Body? = null,
    val responseBody: Body? = null,
) {
    public enum class State(public val rawValue: String) {
        PENDING("pending"),
        COMPLETED("completed"),
        FAILED("failed"),
    }

    /** A captured body, capped at [CAPTURE_LIMIT]. [text] is absent for binary payloads. */
    public data class Body(
        val byteCount: Long,
        val isTruncated: Boolean,
        val contentType: String?,
        val text: String?,
    ) {
        public companion object {
            /** Bodies beyond this are cut, with `isTruncated` set. */
            public const val CAPTURE_LIMIT: Int = 512 * 1024

            /**
             * Captures a body, keeping text when it decodes and the type looks textual.
             * [byteCount] is the full size when [data] holds only the first bytes.
             */
            public fun of(data: ByteArray, contentType: String?, byteCount: Long = data.size.toLong()): Body {
                val capped = if (data.size > CAPTURE_LIMIT) data.copyOf(CAPTURE_LIMIT) else data
                return Body(
                    byteCount = byteCount,
                    isTruncated = byteCount > CAPTURE_LIMIT,
                    contentType = contentType,
                    // A cut can split a character; the text before it is kept.
                    text = if (looksTextual(contentType)) {
                        NectoFilesPlugin.decodeUtf8Head(capped, isComplete = capped.size.toLong() >= byteCount)
                    } else {
                        null
                    },
                )
            }

            private fun looksTextual(contentType: String?): Boolean {
                val type = contentType?.lowercase() ?: return true
                return listOf("json", "text", "xml", "javascript", "x-www-form-urlencoded").any { it in type }
            }
        }
    }

    /** The last path segment, which is what identifies a request when scanning a list. */
    val name: String
        get() {
            val uri = runCatching { URI(url) }.getOrNull() ?: return url
            val last = uri.rawPath?.split('/')?.lastOrNull { it.isNotEmpty() } ?: uri.host ?: url
            val query = uri.rawQuery ?: return last
            return "$last?$query"
        }

    val host: String get() = runCatching { URI(url).host }.getOrNull() ?: ""
}
