// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonArray
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.sdk.NectoOut
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar
import java.util.UUID

/** Somewhere to record what the app did. */
public interface NectoEventReporting {
    public fun report(event: NectoEvent)
}

/** One thing the app did, at one moment. */
public data class NectoEvent(
    val level: Level,
    /** What part of the app this came from: `Router`, `Auth`, `Cache`. */
    val tag: String,
    val message: String,
    /** Anything worth reading once the line has been picked out. */
    val detail: Map<String, String> = emptyMap(),
    val id: String = UUID.randomUUID().toString().uppercase(),
    /** Milliseconds since the epoch. */
    val at: Long = System.currentTimeMillis(),
) {
    public enum class Level(public val rawValue: String) {
        DEBUG("debug"),
        INFO("info"),
        WARN("warn"),
        ERROR("error");

        public companion object {
            public fun of(rawValue: String?): Level? = entries.firstOrNull { it.rawValue == rawValue }
        }
    }
}

/**
 * The app's own log, read from Necto.
 *
 * ```kotlin
 * val events = NectoEventsPlugin()
 * NectoSDK.register(events)
 * events.report(NectoEvent(NectoEvent.Level.WARN, "Cache", "Evicted 240 entries"))
 * ```
 */
public class NectoEventsPlugin : NectoPlugin, NectoEventReporting {
    override val id: String = "event-log"

    override val panel: NectoPluginPanel = NectoPanels.resource("event-log")

    private val lock = Any()
    private val events = ArrayDeque<NectoEvent>()
    private val listeners = NectoListeners()

    override fun register(necto: NectoRegistrar) {
        necto.handle("events.list") { input ->
            val limit = (input["limit"]?.numberValue ?: 500.0).toInt()
            val wanted = input["level"]?.stringValue?.let(NectoEvent.Level::of)
            val page = synchronized(lock) {
                events.asSequence().filter { wanted == null || it.level == wanted }.take(limit).toList()
            }
            jsonObject("events" to jsonArray(page.map(::summary)))
        }

        necto.handle("events.detail") { input ->
            val eventID = input["eventID"]?.stringValue
                ?: throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "eventID is required")
            val event = synchronized(lock) { events.firstOrNull { it.id == eventID } }
                ?: throw NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "No event '$eventID'")
            jsonObject("event" to detail(event))
        }

        // Held open until the caller stops listening; `report` does the sending.
        necto.stream("events.observe") { _, out -> listeners.hold(out) }

        necto.handle("events.clear") {
            synchronized(lock) { events.clear() }
            jsonObject("cleared" to jsonOf(true))
        }
    }

    /**
     * Records one event. Safe to call from any thread, whether or not a host is
     * attached: the app keeps its own log from the moment it starts.
     */
    override fun report(event: NectoEvent) {
        synchronized(lock) {
            events.addFirst(event)
            while (events.size > CAPACITY) events.removeLast()
        }
        listeners.broadcast(jsonObject("event" to summary(event)))
    }

    public companion object {
        /** Keeps memory bounded on a long session. Older events fall off the end. */
        public const val CAPACITY: Int = 5000

        /** What a row needs. `detail` is deliberately absent. */
        internal fun summary(event: NectoEvent): NectoJsonValue = jsonObject(
            "id" to jsonOf(event.id),
            "at" to jsonOf(event.at),
            "level" to jsonOf(event.level.rawValue),
            "tag" to jsonOf(event.tag),
            "message" to jsonOf(event.message),
            "hasDetail" to jsonOf(event.detail.isNotEmpty()),
        )

        internal fun detail(event: NectoEvent): NectoJsonValue {
            val fields = LinkedHashMap(summary(event).objectValue!!)
            fields["detail"] = jsonObject(event.detail.mapValues { jsonOf(it.value) })
            return jsonObject(fields)
        }
    }
}
