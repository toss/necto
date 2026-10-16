// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

/**
 * The single source of truth for the wire protocol.
 *
 * Necto speaks exactly one protocol version. It does not negotiate with peers on other
 * versions; a mismatch fails the connection instead.
 */
public object NectoProtocol {
    public const val NAME: String = "necto"
    public const val CURRENT_VERSION: Int = 1

    public fun isSupported(version: Int): Boolean = version == CURRENT_VERSION
}

/** Who owns a bridge. */
public enum class NectoBridgeKind(public val rawValue: String) {
    /** Provided by the Mac app. */
    DESKTOP("desktop"),

    /** Registered by a connected app. Requires a target. */
    DEVICE("device");

    /** The prefix every bridge of this kind is named under. */
    public val prefix: String get() = "necto.$rawValue."

    public companion object {
        /** Which kind a name belongs to, or null when it belongs to neither. */
        public fun owning(name: String): NectoBridgeKind? = entries.firstOrNull { name.startsWith(it.prefix) }
    }
}

/** How an operation answers. */
public enum class NectoOperationKind(public val rawValue: String) {
    /** Answers once. */
    ONCE("once"),

    /** Keeps answering until it ends. */
    STREAM("stream");

    public companion object {
        public fun of(rawValue: String?): NectoOperationKind? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * Identifies one bridge. `version` counts breaking changes, not releases.
 */
public data class NectoBridgeBinding(val name: String, val version: Int) {
    /** Who answers this bridge, read from the name. */
    val type: NectoBridgeKind? get() = NectoBridgeKind.owning(name)

    /** App contracts cannot be called without a selected target. */
    val requiresTarget: Boolean get() = type == NectoBridgeKind.DEVICE

    /** Identity for provider lookup. Two versions of a name are two bridges. */
    val identity: String get() = "$name@$version"

    public fun toJson(): NectoJsonValue = jsonObject("name" to jsonOf(name), "version" to jsonOf(version))

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoBridgeBinding = NectoBridgeBinding(
            name = json.requireString("name"),
            version = json.requireInt("version"),
        )
    }
}

/** The route a provider claims to satisfy. */
public data class NectoBridgeDescriptor(
    val binding: NectoBridgeBinding,
    val kind: NectoOperationKind,
    val inputSchema: NectoJsonValue = jsonObject(),
    val outputSchema: NectoJsonValue = jsonObject(),
) {
    val name: String get() = binding.name
    val version: Int get() = binding.version
    val identity: String get() = binding.identity

    /** Why this descriptor cannot route a manifest operation, or null when it can. */
    public fun mismatch(operation: NectoOperation): String? = when {
        binding.name != operation.binding.name ->
            "is named '${binding.name}', the manifest declares '${operation.binding.name}'"
        binding.version != operation.binding.version ->
            "is version ${binding.version}, the manifest declares ${operation.binding.version}"
        kind != operation.kind ->
            "is a ${kind.rawValue}, the manifest declares a ${operation.kind.rawValue}"
        else -> null
    }

    public fun toJson(): NectoJsonValue = jsonObject(
        "binding" to binding.toJson(),
        "kind" to jsonOf(kind.rawValue),
        "inputSchema" to inputSchema,
        "outputSchema" to outputSchema,
    )

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoBridgeDescriptor = NectoBridgeDescriptor(
            binding = NectoBridgeBinding.fromJson(json.require("binding")),
            kind = json.requireKind("kind"),
            inputSchema = json["inputSchema"] ?: jsonObject(),
            outputSchema = json["outputSchema"] ?: jsonObject(),
        )
    }
}

/** A provider's descriptors as they travel over the wire. Versioned on its own. */
public data class NectoBridgeCatalog(
    val bridges: List<NectoBridgeDescriptor>,
    val catalogVersion: Int = CURRENT_VERSION,
) {
    public fun toJson(): NectoJsonValue = jsonObject(
        "catalogVersion" to jsonOf(catalogVersion),
        "bridges" to jsonArray(bridges.map { it.toJson() }),
    )

    public companion object {
        public const val CURRENT_VERSION: Int = 1

        public fun fromJson(json: NectoJsonValue): NectoBridgeCatalog = NectoBridgeCatalog(
            catalogVersion = json.requireInt("catalogVersion"),
            bridges = json.requireArray("bridges").map(NectoBridgeDescriptor::fromJson),
        )
    }
}

// Decoding helpers shared by the model types. A missing or mistyped field is a
// malformed message, reported as such rather than defaulted.

internal fun NectoJsonValue.require(key: String): NectoJsonValue =
    this[key] ?: throw NectoJsonException("'$key' is required")

internal fun NectoJsonValue.requireString(key: String): String =
    require(key).stringValue ?: throw NectoJsonException("'$key' must be a string")

internal fun NectoJsonValue.requireBool(key: String): Boolean =
    require(key).boolValue ?: throw NectoJsonException("'$key' must be a boolean")

internal fun NectoJsonValue.requireInt(key: String): Int {
    val value = require(key)
    if (!value.isInteger) throw NectoJsonException("'$key' must be an integer")
    return value.numberValue!!.toInt()
}

internal fun NectoJsonValue.requireArray(key: String): List<NectoJsonValue> =
    require(key).arrayValue ?: throw NectoJsonException("'$key' must be an array")

internal fun NectoJsonValue.requireKind(key: String): NectoOperationKind =
    NectoOperationKind.of(requireString(key)) ?: throw NectoJsonException("'$key' must be once or stream")

/** A present, non-null value; `null` in JSON reads as absent, like Swift's `decodeIfPresent`. */
internal fun NectoJsonValue.optional(key: String): NectoJsonValue? =
    this[key]?.takeUnless { it == NectoJsonValue.Null }

internal fun MutableMap<String, NectoJsonValue>.putIfNotNull(key: String, value: NectoJsonValue?) {
    if (value != null) put(key, value)
}
