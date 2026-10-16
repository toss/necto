// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonArray
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** A tap configuration discovered from the UI, not an exhaustive capability list. */
public data class NectoControlTapGesture(val touchCount: Int, val tapCount: Int)

/** A rectangle in window coordinates. */
public data class NectoRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val minX: Double get() = x
    val minY: Double get() = y
    val maxX: Double get() = x + width
    val maxY: Double get() = y + height
    val midX: Double get() = x + width / 2
    val midY: Double get() = y + height / 2

    public fun insetBy(dx: Double, dy: Double): NectoRect = NectoRect(x + dx, y + dy, width - 2 * dx, height - 2 * dy)
}

public data class NectoPoint(val x: Double, val y: Double)

/**
 * A visible action candidate. IDs are opaque and stable for the element's lifetime;
 * clients must refresh after acting because availability and geometry can change.
 */
public data class NectoControlTarget(
    val id: String,
    val role: String,
    val label: String? = null,
    val identifier: String? = null,
    /** Visible bounds in window coordinates. Android reports pixels. */
    val frame: NectoRect,
    val actions: List<String>,
    val tapGestures: List<NectoControlTapGesture> = emptyList(),
    val value: String? = null,
    val isSecure: Boolean = false,
)

/** Read-only accessibility content. An item is not an action target or a view-tree node. */
public data class NectoAccessibilityItem(
    val role: String,
    val label: String? = null,
    val identifier: String? = null,
    val value: String? = null,
    val isSecure: Boolean = false,
) {
    public fun toJson(): NectoJsonValue {
        val fields = linkedMapOf("role" to jsonOf(role))
        label?.let { fields["label"] = jsonOf(it) }
        identifier?.let { fields["identifier"] = jsonOf(it) }
        if (value != null && !isSecure) fields["value"] = jsonOf(value)
        if (isSecure) fields["isSecure"] = jsonOf(true)
        return jsonObject(fields)
    }
}

/**
 * Discovers action targets and dispatches tap, input, swipe and back requests. The UI
 * work is supplied by the platform: `NectoAndroidPlugins.control(application)` wires the
 * Android View runtime.
 */
public class NectoUIControlPlugin(
    private val actionTargets: suspend () -> List<NectoControlTarget>,
    private val readAccessibility: suspend () -> List<NectoAccessibilityItem>,
    private val action: suspend (operation: String, input: NectoJsonValue) -> NectoJsonValue,
) : NectoPlugin {
    override val id: String = "control"

    override val panel: NectoPluginPanel = NectoPanels.resource("control")

    override fun register(necto: NectoRegistrar) {
        necto.handle("control.actionTargets") { input ->
            val query = input["query"]?.stringValue?.trim().orEmpty()
            val available = actionTargets().filter { it.actions.isNotEmpty() }
            val matches = if (query.isEmpty()) available else available.filter { target ->
                listOf(target.label, target.identifier, target.role).any { it?.contains(query, ignoreCase = true) == true }
            }
            jsonObject("targets" to jsonArray(matches.map(::encode)))
        }
        necto.handle("control.readAccessibility") { input ->
            val query = input["query"]?.stringValue?.trim().orEmpty()
            val items = readAccessibility()
            val matches = if (query.isEmpty()) items else items.filter { item ->
                listOf(item.label, item.identifier, item.role, item.value).any { it?.contains(query, ignoreCase = true) == true }
            }
            jsonObject("items" to jsonArray(matches.map { it.toJson() }))
        }
        for (operation in listOf("tap", "input", "swipe", "back")) {
            necto.handle("control.$operation") { input -> action(operation, input) }
        }
    }

    public companion object {
        internal fun encode(target: NectoControlTarget): NectoJsonValue {
            val frame = with(target.frame) { listOf(x, y, width, height) }.map { jsonOf(if (it.isFinite()) it else 0.0) }
            val fields = linkedMapOf(
                "id" to jsonOf(target.id),
                "role" to jsonOf(target.role),
                "frame" to jsonArray(frame),
                "actions" to jsonArray(target.actions.map(::jsonOf)),
            )
            if (target.tapGestures.isNotEmpty()) {
                fields["tapGestures"] = jsonArray(target.tapGestures.map {
                    jsonObject("touchCount" to jsonOf(it.touchCount), "tapCount" to jsonOf(it.tapCount))
                })
            }
            target.label?.let { fields["label"] = jsonOf(it) }
            target.identifier?.let { fields["identifier"] = jsonOf(it) }
            if (target.value != null && !target.isSecure) fields["value"] = jsonOf(target.value)
            if (target.isSecure) fields["isSecure"] = jsonOf(true)
            return jsonObject(fields)
        }
    }
}

/** Geometry shared by validation and touch delivery. Coordinates refer to visible target bounds. */
public object NectoControlGeometry {
    public fun position(input: NectoJsonValue?, frame: NectoRect): NectoPoint? {
        if (input == null) return null
        val x = input["x"]?.numberValue
        val y = input["y"]?.numberValue
        if (x == null || y == null || x !in 0.0..1.0 || y !in 0.0..1.0) {
            throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "Use position.x and position.y between 0 and 1")
        }
        val bounds = interior(frame)
        return NectoPoint(
            min(bounds.maxX, max(bounds.minX, frame.minX + frame.width * x)),
            min(bounds.maxY, max(bounds.minY, frame.minY + frame.height * y)),
        )
    }

    public fun swipe(start: NectoPoint, direction: String, ratio: Double, frame: NectoRect): NectoPoint {
        val bounds = interior(frame)
        val end = when (direction) {
            "up" -> start.copy(y = max(bounds.minY, start.y - frame.height * ratio))
            "down" -> start.copy(y = min(bounds.maxY, start.y + frame.height * ratio))
            "left" -> start.copy(x = max(bounds.minX, start.x - frame.width * ratio))
            "right" -> start.copy(x = min(bounds.maxX, start.x + frame.width * ratio))
            else -> throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "Choose up, down, left, or right")
        }
        if (hypot(end.x - start.x, end.y - start.y) < 1) {
            throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "There is no room to swipe in that direction")
        }
        return end
    }

    public fun tapPoints(point: NectoPoint, count: Int, frame: NectoRect): List<NectoPoint> {
        if (count <= 1) return listOf(point)
        val half = (count - 1) / 2.0
        val room = min(point.x - frame.minX, frame.maxX - point.x)
        val spacing = minOf(24.0, frame.width / (count + 1), (room - 0.5) / half)
        if (spacing < 1) {
            throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "There is not enough room for these fingers at this position")
        }
        return (0 until count).map { NectoPoint(point.x + (it - half) * spacing, point.y) }
    }

    private fun interior(frame: NectoRect): NectoRect =
        frame.insetBy(min(0.5, frame.width / 4), min(0.5, frame.height / 4))
}
