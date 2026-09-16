// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sdk

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.net.LocalSocket
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import org.json.JSONArray
import org.json.JSONObject

class NectoSDK(context: Context, plugins: List<NectoPluginable>) : AutoCloseable {
    private val app = context.applicationContext.also {
        require(it.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) { "Necto requires a debug build" }
    }
    private val plugins = plugins.toList()
    private val handlers = plugins.associate { plugin ->
        plugin.id to NectoHandler().also { plugin.register(it) }
    }
    private val routes = handlers.values.flatMap { it.registrations.entries }.associate { it.toPair() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var listener: NectoAndroidListener? = null
    @Volatile private var socket: LocalSocket? = null
    private var started = false

    init {
        require(handlers.size == plugins.size) { "Duplicate plugin ID" }
        require(routes.size == handlers.values.sumOf { it.registrations.size }) { "Duplicate contract" }
    }

    @Synchronized
    fun start() {
        check(!started) { "Create a new NectoSDK after stopping" }
        val server = NectoAndroidListener(app)
        listener = server
        started = true
        scope.launch {
            try {
                while (isActive) {
                    val accepted = server.accept()
                    synchronized(this@NectoSDK) {
                        if (!scope.isActive || socket != null) {
                            accepted.disconnect()
                        } else {
                            socket = accepted
                            scope.launch {
                                try { serve(accepted) }
                                catch (error: Exception) {
                                    if (error is CancellationException) throw error
                                } finally {
                                    accepted.disconnect()
                                    socket = null
                                }
                            }
                        }
                    }
                }
            } catch (error: Exception) {
                if (isActive) android.util.Log.e("Necto", "Listener stopped", error)
            } finally {
                server.close()
                listener = null
            }
        }
    }

    private suspend fun serve(socket: LocalSocket) = coroutineScope {
        val session = NectoSession(socket.inputStream, socket.outputStream, socket::disconnect)
        val requests = ConcurrentHashMap<String, Job>()
        try {
            val handshakeDeadline = session.closeAfter(5_000)
            session.send(JSONObject()
                .put("protocolVersion", 1)
                .put("appBundleID", app.packageName)
                .put("appName", app.applicationInfo.loadLabel(app.packageManager).toString())
                .put("appVersion", app.packageManager.getPackageInfo(app.packageName, 0).versionName ?: "")
                .put("deviceName", Build.MODEL)
                .put("osVersion", Build.VERSION.RELEASE)
                .put("sdkVersion", "0.1.0-poc"))
            val ack = session.receive(maximumBytes = 4096)
            check(ack.getBoolean("accepted") && ack.getInt("hostProtocolVersion") == 1) { "Handshake rejected" }
            handshakeDeadline.cancel(false)
            plugins.forEach { plugin ->
                val descriptors = handlers.getValue(plugin.id).registrations.values.map { it.descriptor() }
                val payload = JSONObject().put("pluginID", plugin.id)
                    .put("catalog", JSONObject().put("catalogVersion", 1).put("bridges", JSONArray(descriptors)))
                plugin.panel?.let { payload.put("panel", it.stamp) }
                session.send(JSONObject().put("type", "plugin.register").put("payload", payload))
            }
            while (isActive) {
                val envelope = session.receive()
                val payload = envelope.getJSONObject("payload")
                when (envelope.getString("type")) {
                    "plugin.cancel" -> requests.remove(payload.getString("requestID"))?.cancel()
                    "plugin.invoke" -> {
                        val id = payload.getString("requestID")
                        check(id.length in 1..128) { "Invalid request ID" }
                        check(!requests.containsKey(id)) { "Duplicate active request" }
                        check(requests.size < 32) { "Too many active requests" }
                        val job = launch(start = CoroutineStart.LAZY) {
                            try { invoke(payload, session) } finally {
                                currentCoroutineContext()[Job]?.let { requests.remove(id, it) }
                            }
                        }
                        requests[id] = job
                        job.start()
                    }
                }
            }
        } finally {
            session.close()
            requests.values.forEach { it.cancel() }
        }
    }

    private suspend fun invoke(call: JSONObject, session: NectoSession) {
        val id = call.getString("requestID")
        suspend fun result(output: Any? = null, final: Boolean = true, error: JSONObject? = null) {
            val payload = JSONObject().put("requestID", id).put("isFinal", final)
            output?.let { payload.put("output", it) }
            error?.let { payload.put("error", it) }
            session.send(JSONObject().put("type", "plugin.result").put("payload", payload))
        }
        try {
            val name = call.getString("name")
            val version = call.getInt("version")
            val kind = call.getString("kind")
            val input = call.get("input")
            if (name == "necto.device.plugins.assets" && version == 1 && kind == "once") {
                val panel = plugins.firstOrNull { it.id == (input as? JSONObject)?.optString("pluginID") }?.panel
                    ?: throw NectoError("OPERATION_UNAVAILABLE", "Panel unavailable")
                result(panel.archive())
                return
            }
            val handler = routes["$name@$version"]?.takeIf { it.kind == kind }
                ?: throw NectoError("OPERATION_UNAVAILABLE", "Unknown contract: $name@$version ($kind)")
            val out = NectoHandler.Out { result(it, final = kind == "once") }
            if (kind == "once") withTimeout(30_000) { handler.body(input, out) }
            else handler.body(input, out)
            if (kind == "stream") result()
        } catch (_: TimeoutCancellationException) {
            result(error = JSONObject().put("code", "PROVIDER_FAILED").put("message", "Provider timed out"))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            result(error = JSONObject()
                .put("code", (error as? NectoError)?.code ?: "PROVIDER_FAILED")
                .put("message", (error as? NectoError)?.message ?: "Provider failed"))
        }
    }

    @Synchronized
    override fun close() {
        started = true
        scope.cancel()
        socket?.disconnect()
        listener?.close()
    }
}
