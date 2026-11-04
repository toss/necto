// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException

/**
 * UTF-8 text, or null when the bytes are not UTF-8. A head cut mid-character is
 * still text, so up to three trailing bytes of an incomplete sequence are dropped.
 */
public fun decodeUtf8Head(bytes: ByteArray, isComplete: Boolean): String? {
    val attempts = if (isComplete) 0..0 else 0..minOf(3, bytes.size)
    for (drop in attempts) {
        try {
            return Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes, 0, bytes.size - drop)).toString()
        } catch (_: CharacterCodingException) {
        }
    }
    return null
}
