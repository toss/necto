// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf

/** How a record travels. The shape is the one the panel's manifest declares. */
public object NectoNetworkRecordCoding {
    /** What a row needs. Bodies are deliberately absent. */
    public fun summary(record: NectoNetworkRecord): NectoJsonValue {
        val fields = linkedMapOf(
            "id" to jsonOf(record.id),
            "method" to jsonOf(record.method),
            "url" to jsonOf(record.url),
            "name" to jsonOf(record.name),
            "host" to jsonOf(record.host),
            "state" to jsonOf(record.state.rawValue),
            "startedAtMilliseconds" to jsonOf(record.startedAtMilliseconds),
        )
        record.statusCode?.let { fields["statusCode"] = jsonOf(it) }
        record.durationMilliseconds?.let { fields["durationMilliseconds"] = jsonOf(it) }
        record.responseByteCount?.let { fields["responseByteCount"] = jsonOf(it) }
        record.errorSummary?.let { fields["errorSummary"] = jsonOf(it) }
        return jsonObject(fields)
    }

    /** The summary plus everything a detail pane shows. */
    public fun detail(record: NectoNetworkRecord): NectoJsonValue {
        val fields = LinkedHashMap(summary(record).objectValue!!)
        fields["requestHeaders"] = headers(record.requestHeaders)
        fields["responseHeaders"] = headers(record.responseHeaders)
        fields["curl"] = jsonOf(curl(record))
        record.requestBody?.let { fields["requestBody"] = body(it) }
        record.responseBody?.let { fields["responseBody"] = body(it) }
        return jsonObject(fields)
    }

    private fun headers(headers: Map<String, String>): NectoJsonValue =
        jsonObject(headers.mapValues { jsonOf(it.value) })

    private fun body(body: NectoNetworkRecord.Body): NectoJsonValue {
        val fields = linkedMapOf(
            "byteCount" to jsonOf(body.byteCount),
            "isTruncated" to jsonOf(body.isTruncated),
        )
        body.contentType?.let { fields["contentType"] = jsonOf(it) }
        body.text?.let { fields["text"] = jsonOf(it) }
        return jsonObject(fields)
    }

    /** A command the developer can paste into a terminal to repeat the request. */
    internal fun curl(record: NectoNetworkRecord): String {
        val parts = mutableListOf("curl -X ${record.method}", "'${record.url}'")
        for (key in record.requestHeaders.keys.sorted()) {
            parts += "-H '$key: ${escaped(record.requestHeaders[key].orEmpty())}'"
        }
        record.requestBody?.text?.let { parts += "--data-raw '${escaped(it)}'" }
        return parts.joinToString(" \\\n  ")
    }

    /** A quote inside a single-quoted shell argument has to close and reopen it. */
    private fun escaped(value: String): String = value.replace("'", "'\\''")
}
