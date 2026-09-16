// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sdk

import org.json.JSONObject

interface NectoPluginable {
    val id: String
    val panel: NectoPanel? get() = null
    fun register(necto: NectoHandler)
}

class NectoHandler internal constructor() {
    internal data class Registration(
        val name: String,
        val version: Int,
        val kind: String,
        val body: suspend (Any, Out) -> Unit,
    ) {
        fun descriptor() = JSONObject()
            .put("binding", JSONObject().put("name", name).put("version", version))
            .put("kind", kind)
            .put("inputSchema", JSONObject())
            .put("outputSchema", JSONObject())
    }

    internal val registrations = linkedMapOf<String, Registration>()

    fun handle(name: String, version: Int = 1, body: suspend (Any) -> Any) {
        add(name, version, "once") { input, out -> out.send(body(input)) }
    }

    fun stream(name: String, version: Int = 1, body: suspend (Any, Out) -> Unit) {
        add(name, version, "stream", body)
    }

    private fun add(name: String, version: Int, kind: String, body: suspend (Any, Out) -> Unit) {
        val fullName = "necto.device.$name"
        val key = "$fullName@$version"
        require(version > 0 && name.isNotBlank())
        require(key !in registrations) { "Duplicate contract: $key" }
        registrations[key] = Registration(fullName, version, kind, body)
    }

    class Out internal constructor(private val emit: suspend (Any) -> Unit) {
        suspend fun send(value: Any) = emit(value)
    }
}

class NectoError(val code: String, message: String) : Exception(message)
