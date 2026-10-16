// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.mutablePreferencesOf
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

    private fun assertInvalid(block: () -> Unit) {
        val error = assertThrows(NectoBridgeError::class.java, block)
        assertEquals(NectoBridgeErrorCode.INVALID_INPUT, error.code)
    }
}
