// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

/**
 * A JSON value carried as plugin operation input, output or stream event.
 *
 * Numbers are stored as [Double], like the Swift SDK. JSON Schema's `integer` is decided
 * by whether the stored value has no fractional part.
 */
public sealed class NectoJsonValue {
    public data object Null : NectoJsonValue()
    public data class Bool(val value: Boolean) : NectoJsonValue()
    public data class Number(val value: Double) : NectoJsonValue()
    public data class Str(val value: String) : NectoJsonValue()
    public data class Array(val values: List<NectoJsonValue>) : NectoJsonValue()
    public data class Object(val members: Map<String, NectoJsonValue>) : NectoJsonValue()

    public val boolValue: Boolean? get() = (this as? Bool)?.value
    public val numberValue: Double? get() = (this as? Number)?.value
    public val stringValue: String? get() = (this as? Str)?.value
    public val arrayValue: List<NectoJsonValue>? get() = (this as? Array)?.values
    public val objectValue: Map<String, NectoJsonValue>? get() = (this as? Object)?.members

    /** Whether the value is representable as an integer, used for JSON Schema `integer`. */
    public val isInteger: Boolean
        get() = this is Number && value.isFinite() && Math.rint(value) == value

    public operator fun get(key: String): NectoJsonValue? = objectValue?.get(key)

    /** Serializes as compact UTF-8 JSON text. Non-finite numbers are rejected. */
    public fun toJson(): String = NectoJson.write(this)

    override fun toString(): String = runCatching { toJson() }.getOrDefault(super.toString())

    public companion object {
        public fun of(value: Boolean): NectoJsonValue = Bool(value)
        public fun of(value: String): NectoJsonValue = Str(value)
        public fun of(value: kotlin.Number): NectoJsonValue = Number(value.toDouble())

        /**
         * Converts a Kotlin object graph (null, Boolean, Number, String, CharSequence,
         * Iterable, Array, Map with String keys, or [NectoJsonValue]) into a JSON value.
         * Returns null when any value in the graph is not representable as JSON.
         */
        public fun from(value: Any?): NectoJsonValue? {
            return when (value) {
                null -> Null
                is NectoJsonValue -> value
                is Boolean -> Bool(value)
                is kotlin.Number -> Number(value.toDouble())
                is CharSequence -> Str(value.toString())
                is Map<*, *> -> {
                    val members = LinkedHashMap<String, NectoJsonValue>(value.size)
                    for ((key, element) in value) {
                        if (key !is String) return null
                        members[key] = from(element) ?: return null
                    }
                    Object(members)
                }
                is Iterable<*> -> Array(value.map { from(it) ?: return null })
                is kotlin.Array<*> -> Array(value.map { from(it) ?: return null })
                else -> null
            }
        }

        /** Parses JSON text. Throws [NectoJsonException] when it is malformed. */
        public fun parse(text: String): NectoJsonValue = NectoJson.parse(text)
    }
}

/** The Kotlin object graph this value represents: the inverse of [NectoJsonValue.from]. */
public val NectoJsonValue.plainValue: Any?
    get() = when (this) {
        NectoJsonValue.Null -> null
        is NectoJsonValue.Bool -> value
        is NectoJsonValue.Number -> value
        is NectoJsonValue.Str -> value
        is NectoJsonValue.Array -> values.map { it.plainValue }
        is NectoJsonValue.Object -> members.mapValues { it.value.plainValue }
    }

// Builders, so plugin code reads close to the JSON it produces.

public fun jsonOf(value: String): NectoJsonValue = NectoJsonValue.Str(value)
public fun jsonOf(value: Boolean): NectoJsonValue = NectoJsonValue.Bool(value)
public fun jsonOf(value: Number): NectoJsonValue = NectoJsonValue.Number(value.toDouble())

public fun jsonObject(vararg members: Pair<String, NectoJsonValue>): NectoJsonValue =
    NectoJsonValue.Object(linkedMapOf(*members))

public fun jsonObject(members: Map<String, NectoJsonValue>): NectoJsonValue = NectoJsonValue.Object(members)

public fun jsonArray(vararg values: NectoJsonValue): NectoJsonValue = NectoJsonValue.Array(values.toList())

public fun jsonArray(values: List<NectoJsonValue>): NectoJsonValue = NectoJsonValue.Array(values)

public class NectoJsonException(message: String) : Exception(message)
