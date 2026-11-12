// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

/** Standard codes for a failed plugin call. */
public enum class NectoBridgeErrorCode(public val rawValue: String) {
    INVALID_INPUT("INVALID_INPUT"),
    OPERATION_NOT_FOUND("OPERATION_NOT_FOUND"),
    OPERATION_UNAVAILABLE("OPERATION_UNAVAILABLE"),
    PERMISSION_DENIED("PERMISSION_DENIED"),
    TARGET_DISCONNECTED("TARGET_DISCONNECTED"),
    TIMEOUT("TIMEOUT"),
    CANCELLED("CANCELLED"),
    PROVIDER_FAILED("PROVIDER_FAILED"),
    INVALID_OUTPUT("INVALID_OUTPUT");

    public companion object {
        public fun of(rawValue: String?): NectoBridgeErrorCode? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * A failed plugin call. Throw it from a handler to answer with a specific code; any
 * other exception is reported as [NectoBridgeErrorCode.PROVIDER_FAILED].
 */
public class NectoBridgeError(
    public val code: NectoBridgeErrorCode,
    override val message: String,
    public val operationID: String? = null,
    public val details: NectoJsonValue? = null,
) : Exception(message) {
    override fun toString(): String = "${code.rawValue}: $message"

    public fun toJson(): NectoJsonValue {
        val fields = linkedMapOf("code" to jsonOf(code.rawValue), "message" to jsonOf(message))
        fields.putIfNotNull("operationID", operationID?.let(::jsonOf))
        fields.putIfNotNull("details", details)
        return jsonObject(fields)
    }

    override fun equals(other: Any?): Boolean =
        other is NectoBridgeError && code == other.code && message == other.message &&
            operationID == other.operationID && details == other.details

    override fun hashCode(): Int = listOf(code, message, operationID, details).hashCode()

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoBridgeError = NectoBridgeError(
            code = NectoBridgeErrorCode.of(json.requireString("code"))
                ?: throw NectoJsonException("Unknown error code"),
            message = json.requireString("message"),
            operationID = json.optional("operationID")?.stringValue,
            details = json.optional("details"),
        )
    }
}
