// Copyright (c) 2026 Viva Republica, Inc.

package dev.necto.sdk

import android.content.res.AssetManager
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

class NectoPanel private constructor(private val files: List<Pair<String, ByteArray>>) {
    val stamp: JSONObject get() = JSONObject()
        .put("hash", digest(legacy = true))
        .put("contentHash", digest(legacy = false))

    internal fun archive() = JSONObject().put("files", JSONArray(files.map { (path, bytes) ->
        JSONObject().put("path", path).put("data", Base64.getEncoder().encodeToString(bytes))
    }))

    private fun digest(legacy: Boolean): String {
        val digest = MessageDigest.getInstance("SHA-256")
        fun length(value: Int) = digest.update(ByteBuffer.allocate(8).putLong(value.toLong()).array())
        if (!legacy) length(files.size)
        files.forEach { (path, bytes) ->
            val name = path.toByteArray(Charsets.UTF_8)
            if (!legacy) length(name.size)
            digest.update(name)
            if (legacy) digest.update(0.toByte()) else length(bytes.size)
            digest.update(bytes)
            if (legacy) digest.update(0.toByte())
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        fun fromAssets(assets: AssetManager, root: String): NectoPanel {
            val files = mutableListOf<Pair<String, ByteArray>>()
            fun visit(path: String) {
                val children = assets.list(path).orEmpty()
                if (children.isEmpty()) {
                    files += path.removePrefix("$root/") to assets.open(path).use { it.readBytes() }
                } else {
                    children.filterNot { it.startsWith(".") }.forEach { visit("$path/$it") }
                }
            }
            visit(root)
            return NectoPanel(files.sortedBy { it.first })
        }
    }
}
