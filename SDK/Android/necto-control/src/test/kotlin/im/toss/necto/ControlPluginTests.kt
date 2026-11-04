// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoControlGeometry
import im.toss.necto.plugins.NectoPoint
import im.toss.necto.plugins.NectoRect
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ControlPluginTests {

    @Test
    fun controlGeometryMatchesTheSwiftRules() {
        val frame = NectoRect(0.0, 0.0, 100.0, 50.0)
        assertEquals(NectoPoint(25.0, 25.0), NectoControlGeometry.position(jsonObject("x" to jsonOf(0.25), "y" to jsonOf(0.5)), frame))
        assertEquals(NectoPoint(99.5, 49.5), NectoControlGeometry.position(jsonObject("x" to jsonOf(1), "y" to jsonOf(1)), frame))
        assertFailsWith<NectoBridgeError> { NectoControlGeometry.position(jsonObject("x" to jsonOf(2), "y" to jsonOf(0)), frame) }
        assertEquals(NectoPoint(50.0, 0.5), NectoControlGeometry.swipe(NectoPoint(50.0, 25.0), "up", 0.9, frame))
        val points = NectoControlGeometry.tapPoints(NectoPoint(50.0, 25.0), 3, frame)
        assertEquals(listOf(26.0, 50.0, 74.0), points.map { it.x })
    }}
