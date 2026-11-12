// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

/**
 * A partial JSON Schema implementation used to validate operation payloads.
 *
 * Supports `type`, `properties`, `required`, `additionalProperties` (boolean), `items`,
 * `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `minItems` and `maxItems`.
 * Unsupported keywords are ignored.
 */
public object NectoJsonSchema {
    public data class ValidationFailure(
        /** Where validation failed. Empty for the root value. */
        val path: String,
        val reason: String,
    ) {
        override fun toString(): String = if (path.isEmpty()) reason else "$path: $reason"
    }

    /** Validates a value against a schema, reporting only the first failure. */
    public fun validate(value: NectoJsonValue, schema: NectoJsonValue): ValidationFailure? =
        validate(value, schema, "")

    private fun validate(value: NectoJsonValue, schemaValue: NectoJsonValue, path: String): ValidationFailure? {
        val schema = schemaValue.objectValue ?: return null

        schema["type"]?.stringValue?.let { type ->
            validateType(value, type, path)?.let { return it }
        }

        schema["enum"]?.arrayValue?.let { allowed ->
            if (value !in allowed) return ValidationFailure(path, "is not one of the allowed values")
        }

        when (value) {
            is NectoJsonValue.Number -> {
                val number = value.value
                schema["minimum"]?.numberValue?.let { minimum ->
                    if (number < minimum) return ValidationFailure(path, "must be greater than or equal to ${format(minimum)}")
                }
                schema["maximum"]?.numberValue?.let { maximum ->
                    if (number > maximum) return ValidationFailure(path, "must be less than or equal to ${format(maximum)}")
                }
            }
            is NectoJsonValue.Str -> {
                // Swift counts grapheme clusters; code points are the closest cheap match.
                val length = value.value.codePointCount(0, value.value.length).toDouble()
                schema["minLength"]?.numberValue?.let { minLength ->
                    if (length < minLength) return ValidationFailure(path, "must be at least ${minLength.toInt()} characters")
                }
                schema["maxLength"]?.numberValue?.let { maxLength ->
                    if (length > maxLength) return ValidationFailure(path, "must be at most ${maxLength.toInt()} characters")
                }
            }
            is NectoJsonValue.Array -> {
                val count = value.values.size.toDouble()
                schema["minItems"]?.numberValue?.let { minItems ->
                    if (count < minItems) return ValidationFailure(path, "must contain at least ${minItems.toInt()} items")
                }
                schema["maxItems"]?.numberValue?.let { maxItems ->
                    if (count > maxItems) return ValidationFailure(path, "must contain at most ${maxItems.toInt()} items")
                }
                schema["items"]?.let { itemSchema ->
                    value.values.forEachIndexed { index, element ->
                        validate(element, itemSchema, "$path[$index]")?.let { return it }
                    }
                }
            }
            is NectoJsonValue.Object -> {
                val members = value.members
                schema["required"]?.arrayValue?.forEach { entry ->
                    val key = entry.stringValue ?: return@forEach
                    if (key !in members) return ValidationFailure(join(path, key), "is required")
                }
                val properties = schema["properties"]?.objectValue ?: emptyMap()
                if (schema["additionalProperties"]?.boolValue == false) {
                    for (key in members.keys) {
                        if (key !in properties) return ValidationFailure(join(path, key), "is not declared in the schema")
                    }
                }
                for ((key, propertySchema) in properties) {
                    val member = members[key] ?: continue
                    validate(member, propertySchema, join(path, key))?.let { return it }
                }
            }
            NectoJsonValue.Null, is NectoJsonValue.Bool -> Unit
        }
        return null
    }

    private fun validateType(value: NectoJsonValue, type: String, path: String): ValidationFailure? {
        val matches = when (type) {
            "object" -> value is NectoJsonValue.Object
            "array" -> value is NectoJsonValue.Array
            "string" -> value is NectoJsonValue.Str
            "number" -> value is NectoJsonValue.Number
            "integer" -> value.isInteger
            "boolean" -> value is NectoJsonValue.Bool
            "null" -> value == NectoJsonValue.Null
            else -> true
        }
        return if (matches) null else ValidationFailure(path, "must be of type $type")
    }

    private fun join(path: String, key: String): String = if (path.isEmpty()) key else "$path.$key"

    // Swift interpolates Double as `1.0`; keep the same text so messages match.
    private fun format(number: Double): String = number.toString()
}
