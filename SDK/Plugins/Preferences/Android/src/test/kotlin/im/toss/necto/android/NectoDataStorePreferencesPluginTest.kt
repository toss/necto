// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.mutablePreferencesOf
import androidx.datastore.preferences.core.stringSetPreferencesKey
import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NectoDataStorePreferencesPluginTest {
    private val plugin = NectoDataStorePreferencesPlugin

    /** The largest integer a double holds together with every integer below it. */
    private val largestExact = 9_007_199_254_740_991L

    @Test
    fun longsADoubleHoldsEditAsInt() {
        assertEquals("Int", plugin.typeName(largestExact))
        assertEquals("Int", plugin.typeName(-largestExact))

        val key = longPreferencesKey("count")
        val preferences = mutablePreferencesOf(key to 1L)
        plugin.write(preferences, "count", NectoJsonValue.Number(largestExact.toDouble()), "Int", 1L)
        assertEquals(largestExact, preferences[key])
    }

    /**
     * JSON numbers are all doubles, so 2^53 + 1 reaches the panel as 2^53 and saving the row
     * unchanged would store a different number. Named for itself, the panel leaves it
     * read-only, and a write that reaches the plugin anyway is refused.
     */
    @Test
    fun refusesToEditALongADoubleWouldRound() {
        val stored = 9_007_199_254_740_993L
        assertEquals("Long", plugin.typeName(stored))
        assertEquals("Long", plugin.typeName(Long.MIN_VALUE))
        assertEquals("9007199254740993", plugin.detail("id", stored)["value"]?.stringValue)

        val key = longPreferencesKey("id")
        val preferences = mutablePreferencesOf(key to stored)
        assertInvalid {
            plugin.write(preferences, "id", NectoJsonValue.Number(stored.toDouble()), "Int", stored)
        }
        assertEquals(stored, preferences[key])
    }

    /** At 2^53 the number that arrived may already be a rounded one. */
    @Test
    fun refusesAnIntegerTheJsonNumberMayHaveRounded() {
        assertInvalid {
            plugin.write(mutablePreferencesOf(intPreferencesKey("count") to 1), "count", NectoJsonValue.Number(9_007_199_254_740_992.0), "Int", 1)
        }
        assertInvalid {
            plugin.write(mutablePreferencesOf(), "fresh", NectoJsonValue.Number(-9_007_199_254_740_992.0), "Int", null)
        }
    }

    /** Stored as a Long, it would throw ClassCastException where the app reads an Int. */
    @Test
    fun refusesAnIntKeyAValueOutsideTheIntRange() {
        val key = intPreferencesKey("count")
        val preferences = mutablePreferencesOf(key to 1)
        for (outside in listOf(2_147_483_648.0, -2_147_483_649.0)) {
            assertInvalid { plugin.write(preferences, "count", NectoJsonValue.Number(outside), "Int", 1) }
        }
        assertEquals(1, preferences[key])
        assertInvalid { plugin.write(mutablePreferencesOf(), "fresh", NectoJsonValue.Number(2_147_483_648.0), "Int", null) }

        plugin.write(preferences, "count", NectoJsonValue.Number(2_147_483_647.0), "Int", 1)
        assertEquals(Int.MAX_VALUE, preferences[key])
    }

    /** The StringSet editor sends rows as typed, so no row is mistaken for another. */
    @Test
    fun aStringSetKeepsEveryRowAsTyped() {
        val key = stringSetPreferencesKey("tags")
        val stored = setOf("1", "true", "null", "x", "\"x\"", "{\"id\":1}", "[1,2]")
        val preferences = mutablePreferencesOf(key to stored)
        assertEquals("StringSet", plugin.typeName(stored))

        fun save(vararg rows: String) =
            plugin.write(preferences, "tags", NectoJsonValue.Array(rows.map { NectoJsonValue.Str(it) }), "StringSet", preferences[key])

        save(*stored.toTypedArray())
        assertEquals(stored, preferences[key])
        // Editing `1` to `1.0` saves `1.0`; deleting plain `x` keeps the quoted one.
        save("1.0", "true", "null", "\"x\"", "{\"id\":1}", "[1,2]")
        assertEquals(setOf("1.0", "true", "null", "\"x\"", "{\"id\":1}", "[1,2]"), preferences[key])

        plugin.write(preferences, "tags", NectoJsonValue.Array(listOf(NectoJsonValue.Number(42.0))), "StringSet", preferences[key])
        assertEquals(setOf("42"), preferences[key])
        assertInvalid {
            plugin.write(preferences, "tags", NectoJsonValue.Array(listOf(NectoJsonValue.Object(emptyMap()))), "StringSet", setOf("42"))
        }
    }

    private fun assertInvalid(block: () -> Unit) {
        val error = assertThrows(NectoBridgeError::class.java, block)
        assertEquals(NectoBridgeErrorCode.INVALID_INPUT, error.code)
    }
}
