// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

import java.util.Base64

/**
 * The wrapper every message after the handshake travels in. `type` is the
 * discriminator; `payload` stays opaque until the reader picks a concrete type for it.
 */
public data class NectoEnvelope(val type: Kind, val payload: NectoJsonValue) {
    public enum class Kind(public val rawValue: String) {
        /** App to host: the app contracts this app answers. */
        PLUGIN_REGISTER("plugin.register"),

        /** App to host: an event on a plugin's channel. */
        PLUGIN_EVENT("plugin.event"),

        /** Host to app: run one app contract. */
        PLUGIN_INVOKE("plugin.invoke"),

        /** App to host: the answer to an invoke, or one event of a subscribed stream. */
        PLUGIN_RESULT("plugin.result"),

        /** Host to app: stop a stream that is still running. */
        PLUGIN_CANCEL("plugin.cancel");

        public companion object {
            public fun of(rawValue: String?): Kind? = entries.firstOrNull { it.rawValue == rawValue }
        }
    }

    public fun toJson(): NectoJsonValue = jsonObject("type" to jsonOf(type.rawValue), "payload" to payload)

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoEnvelope = NectoEnvelope(
            type = Kind.of(json.requireString("type")) ?: throw NectoJsonException("Unknown envelope type"),
            payload = json.require("payload"),
        )
    }
}

/**
 * The first message on a new connection, sent by the app. The app speaks first because
 * it is the side that knows its own identity.
 */
public data class NectoHandshakeHello(
    val appBundleID: String,
    val appName: String,
    val appVersion: String = "",
    val deviceName: String,
    val osVersion: String = "",
    val sdkVersion: String,
    /** PNG of the app icon, sent as base64. */
    val appIcon: ByteArray? = null,
    /**
     * The host treats a loopback connection as a simulator and keys it by this value.
     * An Android app reached through `adb forward` sets it to a stable per-device id,
     * or two devices forwarded at once would be the same device.
     */
    val simulatorID: String? = null,
    val protocolVersion: Int = NectoProtocol.CURRENT_VERSION,
) {
    public fun toJson(): NectoJsonValue {
        val fields = linkedMapOf(
            "protocolVersion" to jsonOf(protocolVersion),
            "appBundleID" to jsonOf(appBundleID),
            "appName" to jsonOf(appName),
            "appVersion" to jsonOf(appVersion),
            "deviceName" to jsonOf(deviceName),
            "osVersion" to jsonOf(osVersion),
            "sdkVersion" to jsonOf(sdkVersion),
        )
        fields.putIfNotNull("appIcon", appIcon?.let { jsonOf(Base64.getEncoder().encodeToString(it)) })
        fields.putIfNotNull("simulatorID", simulatorID?.let(::jsonOf))
        return jsonObject(fields)
    }

    override fun equals(other: Any?): Boolean =
        other is NectoHandshakeHello && toJson() == other.toJson()

    override fun hashCode(): Int = toJson().hashCode()

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoHandshakeHello = NectoHandshakeHello(
            protocolVersion = json.requireInt("protocolVersion"),
            appBundleID = json.requireString("appBundleID"),
            appName = json.requireString("appName"),
            appVersion = json.requireString("appVersion"),
            deviceName = json.requireString("deviceName"),
            osVersion = json.requireString("osVersion"),
            sdkVersion = json.requireString("sdkVersion"),
            appIcon = json.optional("appIcon")?.stringValue?.let { Base64.getDecoder().decode(it) },
            simulatorID = json.optional("simulatorID")?.stringValue,
        )
    }
}

/** The host's answer to a hello. */
public data class NectoHandshakeAck(
    val accepted: Boolean,
    val rejection: Rejection? = null,
    val hostProtocolVersion: Int = NectoProtocol.CURRENT_VERSION,
) {
    public enum class Rejection(public val rawValue: String) {
        UNSUPPORTED_PROTOCOL_VERSION("unsupportedProtocolVersion"),
        MISSING_APP_IDENTITY("missingAppIdentity");

        public companion object {
            public fun of(rawValue: String?): Rejection? = entries.firstOrNull { it.rawValue == rawValue }
        }
    }

    public fun toJson(): NectoJsonValue {
        val fields = linkedMapOf("accepted" to jsonOf(accepted))
        fields.putIfNotNull("rejection", rejection?.let { jsonOf(it.rawValue) })
        fields["hostProtocolVersion"] = jsonOf(hostProtocolVersion)
        return jsonObject(fields)
    }

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoHandshakeAck = NectoHandshakeAck(
            accepted = json.requireBool("accepted"),
            rejection = Rejection.of(json.optional("rejection")?.stringValue),
            hostProtocolVersion = json.requireInt("hostProtocolVersion"),
        )

        /** Decides whether a hello can start a session. A version mismatch is refused. */
        public fun evaluate(hello: NectoHandshakeHello): NectoHandshakeAck = when {
            !NectoProtocol.isSupported(hello.protocolVersion) ->
                NectoHandshakeAck(accepted = false, rejection = Rejection.UNSUPPORTED_PROTOCOL_VERSION)
            hello.appBundleID.isEmpty() ->
                NectoHandshakeAck(accepted = false, rejection = Rejection.MISSING_APP_IDENTITY)
            else -> NectoHandshakeAck(accepted = true)
        }
    }
}

/** What a registration says about the panel it carries. */
public data class NectoPanelStamp(val hash: String, val contentHash: String? = null) {
    public fun toJson(): NectoJsonValue {
        val fields = linkedMapOf("hash" to jsonOf(hash))
        fields.putIfNotNull("contentHash", contentHash?.let(::jsonOf))
        return jsonObject(fields)
    }

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoPanelStamp = NectoPanelStamp(
            hash = json.requireString("hash"),
            contentHash = json.optional("contentHash")?.stringValue,
        )
    }
}

/**
 * App to host. What one plugin answers. An empty catalog without a panel removes the
 * plugin: what an app last said about a plugin is the whole truth about it.
 */
public data class NectoPluginRegistration(
    val pluginID: String,
    val catalog: NectoBridgeCatalog,
    val panel: NectoPanelStamp? = null,
) {
    public fun toJson(): NectoJsonValue {
        val fields = linkedMapOf("pluginID" to jsonOf(pluginID), "catalog" to catalog.toJson())
        fields.putIfNotNull("panel", panel?.toJson())
        return jsonObject(fields)
    }

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoPluginRegistration = NectoPluginRegistration(
            pluginID = json.requireString("pluginID"),
            catalog = NectoBridgeCatalog.fromJson(json.require("catalog")),
            panel = json.optional("panel")?.let(NectoPanelStamp::fromJson),
        )
    }
}

/** App to host. An SDK plugin pushing data that a host adapter accumulates. */
public data class NectoPluginEvent(val pluginID: String, val channel: String, val payload: NectoJsonValue) {
    public fun toJson(): NectoJsonValue = jsonObject(
        "pluginID" to jsonOf(pluginID),
        "channel" to jsonOf(channel),
        "payload" to payload,
    )

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoPluginEvent = NectoPluginEvent(
            pluginID = json.requireString("pluginID"),
            channel = json.requireString("channel"),
            payload = json.require("payload"),
        )
    }
}

/** Host to app. One call against a registered app contract. */
public data class NectoPluginInvocation(
    val requestID: String,
    val name: String,
    val version: Int,
    val kind: NectoOperationKind,
    val input: NectoJsonValue,
) {
    public fun toJson(): NectoJsonValue = jsonObject(
        "requestID" to jsonOf(requestID),
        "name" to jsonOf(name),
        "version" to jsonOf(version),
        "kind" to jsonOf(kind.rawValue),
        "input" to input,
    )

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoPluginInvocation = NectoPluginInvocation(
            requestID = json.requireString("requestID"),
            name = json.requireString("name"),
            version = json.requireInt("version"),
            kind = json.requireKind("kind"),
            input = json["input"] ?: NectoJsonValue.Null,
        )
    }
}

/**
 * App to host. The reply to an invocation. A `once` call produces exactly one of these;
 * a `stream` produces many with [isFinal] false, then one final message that carries
 * either an error or nothing at all.
 */
public data class NectoPluginResult(
    val requestID: String,
    val output: NectoJsonValue? = null,
    val error: NectoBridgeError? = null,
    val isFinal: Boolean = true,
) {
    public fun toJson(): NectoJsonValue {
        val fields = linkedMapOf("requestID" to jsonOf(requestID))
        fields.putIfNotNull("output", output)
        fields.putIfNotNull("error", error?.toJson())
        fields["isFinal"] = jsonOf(isFinal)
        return jsonObject(fields)
    }

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoPluginResult = NectoPluginResult(
            requestID = json.requireString("requestID"),
            output = json.optional("output"),
            error = json.optional("error")?.let(NectoBridgeError::fromJson),
            isFinal = json.requireBool("isFinal"),
        )
    }
}

/** Host to app. Ends a stream the host no longer reads. */
public data class NectoPluginCancellation(val requestID: String) {
    public fun toJson(): NectoJsonValue = jsonObject("requestID" to jsonOf(requestID))

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoPluginCancellation =
            NectoPluginCancellation(json.requireString("requestID"))
    }
}
