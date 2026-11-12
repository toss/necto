// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonArray
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoPanels
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar
import kotlinx.coroutines.flow.first

/**
 * What the app keeps in Jetpack DataStore Preferences, read from Necto: the Android
 * counterpart of the iOS UserDefaults plugin, answering the same `preferences.*` contracts.
 *
 * DataStore allows one instance per file, so the app hands over the instances it already
 * owns, by name. The first is the default store (`standard` also reaches it); a store the
 * app did not hand over cannot be read.
 *
 * ```kotlin
 * val Context.settings by preferencesDataStore("settings")
 * NectoDataStorePreferencesPlugin(mapOf("settings" to context.settings))
 * ```
 */
public class NectoDataStorePreferencesPlugin(
    private val stores: Map<String, DataStore<Preferences>>,
) : NectoPlugin {
    init {
        require(stores.isNotEmpty()) { "Pass at least one DataStore" }
    }

    override val id: String = "preferences"

    override val panel: NectoPluginPanel = NectoPanels.resource("preferences")

    override fun register(necto: NectoRegistrar) {
        necto.handle("preferences.list") { input ->
            val all = values(store(input["suite"]?.stringValue))
            val prefix = input["prefix"]?.stringValue.orEmpty()
            val entries = all.entries
                .filter { prefix.isEmpty() || it.key.startsWith(prefix) }
                .sortedBy { it.key }
                .map { summary(it.key, it.value) }
            jsonObject("entries" to jsonArray(entries), "total" to jsonOf(all.size))
        }

        necto.handle("preferences.detail") { input ->
            val key = requiredKey(input)
            val value = values(store(input["suite"]?.stringValue))[key]
                ?: throw NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "No key '$key'")
            jsonObject("entry" to detail(key, value))
        }

        necto.handle("preferences.suites") {
            jsonObject("suites" to jsonArray(stores.keys.map(::jsonOf)))
        }

        // Writing into a store a running app is reading from can change what it does next.
        necto.handle("preferences.set") { input ->
            val key = requiredKey(input)
            val value = input["value"] ?: throw invalid("value is required")
            val hint = input["type"]?.stringValue
            val store = store(input["suite"]?.stringValue)
            val updated = store.edit { preferences ->
                val existing = preferences.asMap().entries.firstOrNull { it.key.name == key }?.value
                write(preferences, key, value, hint, existing)
            }
            val stored = updated.asMap().entries.firstOrNull { it.key.name == key }?.value
            jsonObject("entry" to detail(key, stored))
        }

        necto.handle("preferences.remove") { input ->
            val key = requiredKey(input)
            store(input["suite"]?.stringValue).edit { preferences -> removeNamed(preferences, key) }
            jsonObject("removed" to jsonOf(true))
        }
    }

    private fun store(suite: String?): DataStore<Preferences> {
        if (suite == null || suite == STANDARD) return stores.values.first()
        return stores[suite] ?: throw invalid("This app does not offer the suite '$suite'")
    }

    private suspend fun values(store: DataStore<Preferences>): Map<String, Any> =
        store.data.first().asMap().mapKeys { it.key.name }

    public companion object {
        public const val STANDARD: String = "standard"

        /** Enough of a value to recognise a row by. */
        internal const val PREVIEW_LIMIT: Int = 120

        // JSON numbers are doubles, which hold every integer only below 2^53.
        private const val MAX_EXACT_INTEGER: Long = 9_007_199_254_740_992L

        private fun invalid(message: String) = NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, message)

        private fun requiredKey(input: NectoJsonValue): String =
            input["key"]?.stringValue?.takeIf { it.isNotEmpty() } ?: throw invalid("key must be a non-empty string")

        internal fun summary(key: String, value: Any?): NectoJsonValue {
            val rendered = describe(value)
            return jsonObject(
                "key" to jsonOf(key),
                "type" to jsonOf(typeName(value)),
                "preview" to jsonOf(rendered.take(PREVIEW_LIMIT)),
                "isTruncated" to jsonOf(rendered.length > PREVIEW_LIMIT),
            )
        }

        internal fun detail(key: String, value: Any?): NectoJsonValue = jsonObject(
            "key" to jsonOf(key),
            "type" to jsonOf(typeName(value)),
            "value" to jsonOf(describe(value)),
        )

        /**
         * Named for the editor the panel opens: it knows Bool, Int, Double and StringSet. A
         * Long edits as an Int and a Float as a Double; [write] keeps the stored type. A Long
         * a double would round is named for itself, which the panel leaves read-only rather
         * than saving the rounded number back. A string set is a StringSet, whose editor
         * sends each row as typed, not as the JSON it parses to.
         */
        internal fun typeName(value: Any?): String = when (value) {
            is Boolean -> "Bool"
            is Int -> "Int"
            is Long -> if (fitsJsonNumber(value)) "Int" else "Long"
            is Float, is Double -> "Double"
            is Set<*> -> "StringSet"
            is String -> "String"
            is ByteArray -> "Data"
            else -> value?.javaClass?.simpleName ?: "Null"
        }

        /**
         * One line for simple values, pretty JSON for a string set, which is also what the
         * editor opens. Bytes are described rather than rendered.
         */
        internal fun describe(value: Any?): String = when (value) {
            null -> "null"
            is String -> value
            is ByteArray -> "${value.size} bytes"
            is Set<*> -> {
                val items = value.map { it.toString() }.sorted()
                if (items.isEmpty()) "[\n\n]" else items.joinToString(",\n", "[\n", "\n]") { "  " + jsonOf(it).toJson() }
            }
            else -> value.toString()
        }

        /**
         * Set elements as the strings DataStore stores. The panel's StringSet editor sends
         * every row as a string, exactly as typed. A number or a Bool, which another caller
         * may send, is stored as its JSON text.
         */
        private fun strings(values: List<NectoJsonValue>): Set<String> = values.map { value ->
            value.stringValue
                ?: if (value is NectoJsonValue.Object || value is NectoJsonValue.Array) {
                    throw invalid("DataStore stores sets of strings only")
                } else {
                    value.toJson()
                }
        }.toSet()

        /** Drops [name] whatever its type: keys compare by name alone. */
        internal fun removeNamed(preferences: MutablePreferences, name: String) {
            preferences.asMap().keys.filter { it.name == name }.forEach { preferences.remove(it) }
        }

        /**
         * Stores [value] in the type the key already has. JSON numbers are all doubles, so
         * without the stored type an Int would come back a Double, silently. A key of
         * another type under the same name is replaced.
         */
        internal fun write(preferences: MutablePreferences, key: String, value: NectoJsonValue, hint: String?, existing: Any?) {
            if (existing is ByteArray) throw invalid("Binary values cannot be edited")
            if (existing is Long && !fitsJsonNumber(existing)) {
                throw invalid("$existing cannot be edited: a JSON number would round it")
            }
            // The app reads an Int key as an Int: a Long stored there would throw
            // ClassCastException in the app, not here.
            if ((existing is Int || (existing == null && hint == "Int")) && value is NectoJsonValue.Number &&
                value.value !in Int.MIN_VALUE.toDouble()..Int.MAX_VALUE.toDouble()
            ) {
                throw invalid("${value.value.toLong()} is not a value an Int can hold")
            }
            removeNamed(preferences, key)
            when (value) {
                is NectoJsonValue.Bool -> preferences[booleanPreferencesKey(key)] = value.value
                is NectoJsonValue.Number -> {
                    val number = value.value
                    val integral = value.isInteger
                    when {
                        existing is Long -> preferences[longPreferencesKey(key)] = integerOrThrow(number, integral).toLong()
                        existing is Float -> preferences[floatPreferencesKey(key)] = number.toFloat()
                        existing is Double -> preferences[doublePreferencesKey(key)] = number
                        existing is Int || (existing == null && (hint == "Int" || (hint == null && integral))) -> {
                            val integer = integerOrThrow(number, integral)
                            if (integer in Int.MIN_VALUE.toDouble()..Int.MAX_VALUE.toDouble()) {
                                preferences[intPreferencesKey(key)] = integer.toInt()
                            } else {
                                preferences[longPreferencesKey(key)] = integer.toLong()
                            }
                        }
                        else -> preferences[doublePreferencesKey(key)] = number
                    }
                }
                is NectoJsonValue.Str -> preferences[stringPreferencesKey(key)] = value.value
                is NectoJsonValue.Array -> {
                    preferences[stringSetPreferencesKey(key)] = strings(value.values)
                }
                is NectoJsonValue.Object -> throw invalid("DataStore Preferences cannot store a dictionary")
                NectoJsonValue.Null -> Unit
            }
        }

        private fun fitsJsonNumber(value: Long): Boolean = value > -MAX_EXACT_INTEGER && value < MAX_EXACT_INTEGER

        /** At 2^53 and beyond, the number that arrived may already be a rounded one. */
        private fun integerOrThrow(number: Double, integral: Boolean): Double {
            if (!integral) throw invalid("'$number' is not an integer")
            if (kotlin.math.abs(number) >= MAX_EXACT_INTEGER.toDouble()) {
                throw invalid("${number.toLong()} is not a value an Int can hold")
            }
            return number
        }
    }
}
