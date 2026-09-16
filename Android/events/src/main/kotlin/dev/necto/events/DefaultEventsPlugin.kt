// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.events

import android.content.Context
import dev.necto.sdk.NectoError
import dev.necto.sdk.NectoHandler
import dev.necto.sdk.NectoPanel
import dev.necto.sdk.NectoPluginable
import java.util.UUID
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import org.json.JSONArray
import org.json.JSONObject

class DefaultEventsPlugin(context: Context) : NectoPluginable {
    override val id = "event-log"
    override val panel = NectoPanel.fromAssets(context.assets, "event-log")
    private val lock = Any()
    private data class Record(val json: JSONObject, val bytes: Int)
    private val events = ArrayDeque<Record>()
    private var historyBytes = 0
    private val changes = MutableSharedFlow<JSONObject>(
        extraBufferCapacity = 128, onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    override fun register(necto: NectoHandler) {
        necto.handle("events.list") { value ->
            val input = value as? JSONObject ?: throw NectoError("INVALID_INPUT", "Expected an object")
            val limit = input.optInt("limit", 500).coerceIn(1, 5000)
            val level = input.optString("level")
            val page = synchronized(lock) {
                events.asSequence().map { it.json }.filter { level.isEmpty() || it.getString("level") == level }.take(limit).map(::summary).toList()
            }
            JSONObject().put("events", JSONArray(page))
        }
        necto.handle("events.detail") { value ->
            val input = value as? JSONObject ?: throw NectoError("INVALID_INPUT", "Expected an object")
            val id = input.optString("eventID")
            if (id.isEmpty()) throw NectoError("INVALID_INPUT", "eventID is required")
            val event = synchronized(lock) { events.firstOrNull { it.json.getString("id") == id }?.json }
                ?: throw NectoError("OPERATION_UNAVAILABLE", "No event '$id'")
            JSONObject().put("event", event)
        }
        necto.stream("events.observe") { _, out ->
            changes.collect { out.send(JSONObject().put("event", summary(it))) }
        }
        necto.handle("events.clear") {
            synchronized(lock) { events.clear(); historyBytes = 0 }
            JSONObject().put("cleared", true)
        }
    }

    fun report(message: String, tag: String = "App", level: String = "info", detail: Map<String, String> = emptyMap()) {
        require(level in setOf("debug", "info", "warn", "error"))
        val boundedDetail = detail.entries.take(16).associate { it.key.take(64) to it.value.take(256) }
        val event = JSONObject().put("id", UUID.randomUUID().toString())
            .put("at", System.currentTimeMillis()).put("level", level).put("tag", tag.take(128))
            .put("message", message.take(1024)).put("hasDetail", boundedDetail.isNotEmpty()).put("detail", JSONObject(boundedDetail))
        synchronized(lock) {
            val record = Record(event, event.toString().toByteArray(Charsets.UTF_8).size)
            events.addFirst(record)
            historyBytes += record.bytes
            while (events.size > 5000 || historyBytes > 8 * 1024 * 1024) {
                historyBytes -= events.removeLast().bytes
            }
            changes.tryEmit(event)
        }
    }

    private fun summary(event: JSONObject) = JSONObject(event.toString()).also { it.remove("detail") }
}
