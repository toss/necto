// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.jsonArray
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar

/**
 * The standard way to report network traffic to Necto.
 *
 * An interface, not a capture mechanism: the app reports and Necto only carries.
 * `necto-okhttp` is one ready-made source for apps that use OkHttp.
 *
 * ```kotlin
 * val network = NectoNetworkPlugin()
 * NectoSDK.register(network)
 * network.report(record)
 * ```
 */
public class NectoNetworkPlugin : NectoPlugin, NectoNetworkReporting {
    override val id: String = "network-logger"

    override val panel: NectoPluginPanel = NectoPanels.resource("network-logger")

    private val lock = Any()
    private val records = ArrayList<NectoNetworkRecord>()
    private val observers = NectoListeners()

    override fun register(necto: NectoRegistrar) {
        necto.handle("network-records.list") { input ->
            val limit = (input["limit"]?.numberValue ?: 200.0).toInt()
            val page = synchronized(lock) { records.take(limit) }
            jsonObject("records" to jsonArray(page.map(NectoNetworkRecordCoding::summary)))
        }

        necto.handle("network-records.detail") { input ->
            val recordID = input["recordID"]?.stringValue
                ?: throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "recordID is required")
            val record = synchronized(lock) { records.firstOrNull { it.id == recordID } }
                ?: throw NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "No record '$recordID'")
            jsonObject("record" to NectoNetworkRecordCoding.detail(record))
        }

        // Held open until the caller stops listening; `report` does the sending.
        necto.stream("network-records.observe") { _, out -> observers.hold(out) }

        necto.handle("network-records.clear") {
            synchronized(lock) { records.clear() }
            jsonObject("cleared" to jsonOf(true))
        }
    }

    /**
     * Reports one request. Safe to call from any thread. Send a record twice, keeping
     * the same `id`, to show progress: Necto replaces rather than appends.
     */
    override fun report(record: NectoNetworkRecord) {
        synchronized(lock) {
            val index = records.indexOfFirst { it.id == record.id }
            if (index >= 0) {
                records[index] = record
            } else {
                records.add(0, record)
                while (records.size > CAPACITY) records.removeAt(records.lastIndex)
            }
        }
        observers.broadcast(jsonObject("record" to NectoNetworkRecordCoding.summary(record)))
    }

    public companion object {
        /** Keeps memory bounded on a long session. Older records fall off the end. */
        public const val CAPACITY: Int = 2000
    }
}
