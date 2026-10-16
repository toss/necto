// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

/**
 * A small JSON reader and writer, so the SDK stays dependency free like the Swift one.
 *
 * The writer emits integral numbers without a fraction (`1`, not `1.0`), because the
 * host decodes counts such as `version` and `protocolVersion` as Swift `Int`.
 */
internal object NectoJson {
    // Doubles represent every integer up to 2^53 exactly.
    private const val MAX_EXACT_INTEGER = 9_007_199_254_740_992.0

    // The device listener's limit: a hostile peer cannot recurse the reader deep enough
    // to exhaust the stack of the thread that answers it.
    private const val MAX_DEPTH = 64

    fun write(value: NectoJsonValue): String = StringBuilder().also { write(value, it) }.toString()

    private fun write(value: NectoJsonValue, out: StringBuilder) {
        when (value) {
            NectoJsonValue.Null -> out.append("null")
            is NectoJsonValue.Bool -> out.append(if (value.value) "true" else "false")
            is NectoJsonValue.Number -> writeNumber(value.value, out)
            is NectoJsonValue.Str -> writeString(value.value, out)
            is NectoJsonValue.Array -> {
                out.append('[')
                value.values.forEachIndexed { index, element ->
                    if (index > 0) out.append(',')
                    write(element, out)
                }
                out.append(']')
            }
            is NectoJsonValue.Object -> {
                out.append('{')
                var first = true
                for ((key, element) in value.members) {
                    if (!first) out.append(',')
                    first = false
                    writeString(key, out)
                    out.append(':')
                    write(element, out)
                }
                out.append('}')
            }
        }
    }

    private fun writeNumber(number: Double, out: StringBuilder) {
        if (!number.isFinite()) throw NectoJsonException("JSON numbers must be finite")
        if (Math.rint(number) == number && kotlin.math.abs(number) <= MAX_EXACT_INTEGER) {
            out.append(number.toLong())
        } else {
            out.append(number.toString())
        }
    }

    private fun writeString(text: String, out: StringBuilder) {
        out.append('"')
        for (character in text) {
            when (character) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (character < ' ') {
                    out.append("\\u").append(String.format("%04x", character.code))
                } else {
                    out.append(character)
                }
            }
        }
        out.append('"')
    }

    fun parse(text: String): NectoJsonValue {
        val parser = Parser(text)
        val value = parser.readValue(depth = 0)
        parser.skipWhitespace()
        if (!parser.atEnd) parser.fail("Unexpected trailing characters")
        return value
    }

    private class Parser(private val text: String) {
        private var index = 0
        val atEnd: Boolean get() = index >= text.length

        fun fail(reason: String): Nothing = throw NectoJsonException("$reason at offset $index")

        fun skipWhitespace() {
            while (index < text.length) {
                when (text[index]) {
                    ' ', '\n', '\r', '\t' -> index++
                    else -> return
                }
            }
        }

        fun readValue(depth: Int): NectoJsonValue {
            if (depth > MAX_DEPTH) fail("JSON nests too deeply")
            skipWhitespace()
            if (atEnd) fail("Unexpected end of JSON")
            return when (val character = text[index]) {
                '{' -> readObject(depth)
                '[' -> readArray(depth)
                '"' -> NectoJsonValue.Str(readString())
                't' -> readLiteral("true", NectoJsonValue.Bool(true))
                'f' -> readLiteral("false", NectoJsonValue.Bool(false))
                'n' -> readLiteral("null", NectoJsonValue.Null)
                else -> if (character == '-' || character in '0'..'9') readNumber() else fail("Unexpected '$character'")
            }
        }

        private fun readLiteral(literal: String, value: NectoJsonValue): NectoJsonValue {
            if (!text.startsWith(literal, index)) fail("Expected '$literal'")
            index += literal.length
            return value
        }

        private fun readObject(depth: Int): NectoJsonValue {
            index++ // {
            val members = LinkedHashMap<String, NectoJsonValue>()
            skipWhitespace()
            if (!atEnd && text[index] == '}') {
                index++
                return NectoJsonValue.Object(members)
            }
            while (true) {
                skipWhitespace()
                if (atEnd || text[index] != '"') fail("Expected a key")
                val key = readString()
                skipWhitespace()
                if (atEnd || text[index] != ':') fail("Expected ':'")
                index++
                members[key] = readValue(depth + 1)
                skipWhitespace()
                if (atEnd) fail("Unterminated object")
                when (text[index++]) {
                    ',' -> continue
                    '}' -> return NectoJsonValue.Object(members)
                    else -> { index--; fail("Expected ',' or '}'") }
                }
            }
        }

        private fun readArray(depth: Int): NectoJsonValue {
            index++ // [
            val values = ArrayList<NectoJsonValue>()
            skipWhitespace()
            if (!atEnd && text[index] == ']') {
                index++
                return NectoJsonValue.Array(values)
            }
            while (true) {
                values.add(readValue(depth + 1))
                skipWhitespace()
                if (atEnd) fail("Unterminated array")
                when (text[index++]) {
                    ',' -> continue
                    ']' -> return NectoJsonValue.Array(values)
                    else -> { index--; fail("Expected ',' or ']'") }
                }
            }
        }

        private fun readString(): String {
            index++ // opening quote
            val out = StringBuilder()
            while (true) {
                if (atEnd) fail("Unterminated string")
                val character = text[index++]
                when {
                    character == '"' -> return out.toString()
                    character == '\\' -> {
                        if (atEnd) fail("Unterminated escape")
                        when (val escaped = text[index++]) {
                            '"' -> out.append('"')
                            '\\' -> out.append('\\')
                            '/' -> out.append('/')
                            'b' -> out.append('\b')
                            'f' -> out.append('\u000C')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                if (index + 4 > text.length) fail("Truncated unicode escape")
                                val code = text.substring(index, index + 4).toIntOrNull(16) ?: fail("Invalid unicode escape")
                                out.append(code.toChar())
                                index += 4
                            }
                            else -> fail("Invalid escape '\\$escaped'")
                        }
                    }
                    character < ' ' -> fail("Control character in string")
                    else -> out.append(character)
                }
            }
        }

        private fun readNumber(): NectoJsonValue {
            val start = index
            if (text[index] == '-') index++
            while (index < text.length && text[index] in "0123456789.eE+-") index++
            val literal = text.substring(start, index)
            val number = literal.toDoubleOrNull() ?: fail("Invalid number '$literal'")
            return NectoJsonValue.Number(number)
        }
    }
}
