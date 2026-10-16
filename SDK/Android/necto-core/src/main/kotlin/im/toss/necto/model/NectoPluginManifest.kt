// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

/** An operation declared in the manifest. No field is optional. */
public data class NectoOperation(
    val id: String,
    val title: String,
    val description: String,
    val kind: NectoOperationKind,
    val binding: NectoBridgeBinding,
    val inputSchema: NectoJsonValue,
    val outputSchema: NectoJsonValue,
    /** `0` means no limit. Streams normally use `0`. */
    val timeoutMs: Int,
) {
    public fun toJson(): NectoJsonValue = jsonObject(
        "id" to jsonOf(id),
        "title" to jsonOf(title),
        "description" to jsonOf(description),
        "kind" to jsonOf(kind.rawValue),
        "binding" to binding.toJson(),
        "inputSchema" to inputSchema,
        "outputSchema" to outputSchema,
        "timeoutMs" to jsonOf(timeoutMs),
    )

    public companion object {
        public fun fromJson(json: NectoJsonValue): NectoOperation = NectoOperation(
            id = json.requireString("id"),
            title = json.requireString("title"),
            description = json.requireString("description"),
            kind = json.requireKind("kind"),
            binding = NectoBridgeBinding.fromJson(json.require("binding")),
            inputSchema = json.require("inputSchema"),
            outputSchema = json.require("outputSchema"),
            timeoutMs = json.requireInt("timeoutMs"),
        )
    }
}

/** The typed form of a plugin's `manifest.json`. */
public data class NectoPluginManifest(
    val id: String,
    val name: String,
    val description: String,
    val version: String,
    val author: String,
    val authorURL: String? = null,
    /** An SF Symbols name, drawn by the Mac host. */
    val iconSystemName: String,
    val assets: List<String>,
    val allowedOrigins: List<String>,
    val operations: List<NectoOperation>,
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
) {
    /** A plugin needs a connected app as soon as one operation binds to an app contract. */
    val requiresTarget: Boolean get() = operations.any { it.binding.requiresTarget }

    public fun operation(id: String): NectoOperation? = operations.firstOrNull { it.id == id }

    /**
     * Checks the manifest for internal consistency. Throws [NectoManifestValidationError].
     */
    public fun validate() {
        if (schemaVersion != CURRENT_SCHEMA_VERSION) {
            throw NectoManifestValidationError("schemaVersion $schemaVersion is not supported. Only $CURRENT_SCHEMA_VERSION is accepted.")
        }
        requireIdentifier(id)
        for ((field, value) in listOf("name" to name, "description" to description, "author" to author)) {
            if (value.isBlank()) throw NectoManifestValidationError("$field must not be empty.")
        }
        if (NectoSemanticVersion.parse(version) == null) {
            throw NectoManifestValidationError("version '$version' is not a valid semantic version.")
        }
        for (origin in allowedOrigins) {
            if (!isValidOrigin(origin)) {
                throw NectoManifestValidationError("allowedOrigins entry '$origin' must be 'self' or an https origin.")
            }
        }
        val seenIDs = HashSet<String>()
        val seenBindings = HashSet<String>()
        for (operation in operations) {
            requireIdentifier(operation.id)
            if (!seenIDs.add(operation.id)) throw NectoManifestValidationError("Duplicate operation id '${operation.id}'.")
            if (operation.timeoutMs < 0) {
                throw NectoManifestValidationError("Operation '${operation.id}' must declare a timeoutMs of 0 or greater.")
            }
            val name = operation.binding.name
            if (operation.binding.type == null) {
                throw NectoManifestValidationError(
                    "Operation '${operation.id}' binds to '$name', which names no owner. " +
                        "A bridge is called '${NectoBridgeKind.DEVICE.prefix}…' or '${NectoBridgeKind.DESKTOP.prefix}…'.",
                )
            }
            if (!seenBindings.add(operation.binding.identity)) {
                throw NectoManifestValidationError("Operation '${operation.id}' binds to '$name', which another operation already binds to.")
            }
        }
    }

    public fun toJson(): NectoJsonValue {
        val fields = linkedMapOf(
            "schemaVersion" to jsonOf(schemaVersion),
            "id" to jsonOf(id),
            "name" to jsonOf(name),
            "description" to jsonOf(description),
            "version" to jsonOf(version),
            "author" to jsonOf(author),
        )
        fields.putIfNotNull("authorUrl", authorURL?.let(::jsonOf))
        fields["icon"] = jsonObject("systemName" to jsonOf(iconSystemName))
        fields["assets"] = jsonArray(assets.map(::jsonOf))
        fields["allowedOrigins"] = jsonArray(allowedOrigins.map(::jsonOf))
        fields["operations"] = jsonArray(operations.map { it.toJson() })
        return jsonObject(fields)
    }

    public companion object {
        public const val CURRENT_SCHEMA_VERSION: Int = 1

        public fun fromJson(json: NectoJsonValue): NectoPluginManifest = NectoPluginManifest(
            schemaVersion = json.requireInt("schemaVersion"),
            id = json.requireString("id"),
            name = json.requireString("name"),
            description = json.requireString("description"),
            version = json.requireString("version"),
            author = json.requireString("author"),
            authorURL = json.optional("authorUrl")?.stringValue,
            iconSystemName = json.require("icon").requireString("systemName"),
            assets = json.requireArray("assets").map { it.stringValue ?: throw NectoJsonException("assets must be strings") },
            allowedOrigins = json.requireArray("allowedOrigins")
                .map { it.stringValue ?: throw NectoJsonException("allowedOrigins must be strings") },
            operations = json.requireArray("operations").map(NectoOperation::fromJson),
        )

        private fun requireIdentifier(value: String) {
            val valid = value.isNotEmpty() && value.all {
                it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '.' || it == '_' || it == '-'
            }
            if (!valid) {
                throw NectoManifestValidationError("Identifier '$value' may only contain A-Z, a-z, 0-9, '.', '_' and '-'.")
            }
        }

        private fun isValidOrigin(value: String): Boolean {
            if (value == "self") return true
            if (!value.startsWith("https://")) return false
            val host = runCatching { java.net.URI(value).host }.getOrNull()
            return !host.isNullOrEmpty()
        }
    }
}

public class NectoManifestValidationError(message: String) : Exception(message)
