// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.UUID

/**
 * Generates traffic for the network plugin to show.
 *
 * Requests are real, so the plugin displays real timings, bodies and failures rather
 * than fixtures. They cover the shapes a REST client actually produces — every method,
 * a request body, a large response, a slow one, a 404, and a transport failure —
 * because a plugin that only ever sees one healthy GET is a plugin whose layout has not
 * been tested.
 */
private class Call(val title: String, val method: String, val url: String, val body: Map<String, String>? = null)

private class Attempt(val title: String, val method: String, val outcome: String, val milliseconds: Long) {
    val id: String = UUID.randomUUID().toString()
}

/**
 * Answered by [LocalApi] inside this app.
 *
 * Nothing here needs the internet: the plugin captures a request where the OkHttp
 * interceptor sees it, long before it would reach a network. Serving the demo locally
 * means it behaves the same offline, on a corporate connection that inspects TLS, and
 * on a device that has never been online.
 */
private fun calls(): List<Call> {
    val api = LocalApi.origin
    return listOf(
        Call("List posts", "GET", "$api/posts"),
        Call("Get one post", "GET", "$api/posts/1"),
        Call("Create a post", "POST", "$api/posts", mapOf("title" to "Necto", "body" to "Sent from Necto Example", "userId" to "1")),
        Call("Update a post", "PATCH", "$api/posts/1", mapOf("title" to "Edited by Necto")),
        Call("End the session", "DELETE", "$api/session"),
        // Past the capture limit, so the plugin has to truncate the body.
        Call("Large response", "GET", "$api/large"),
        // Answers after two seconds, so a slow row sits beside the fast ones.
        Call("Slow response", "GET", "$api/slow"),
        Call("Not found", "GET", "$api/posts/999"),
        Call("Server error", "GET", "$api/error"),
        // The one request that genuinely leaves the app, so a transport failure is
        // shown as well as an HTTP one.
        Call("Unresolvable host", "GET", "https://necto-example.invalid/missing"),
    )
}

@Composable
fun NetworkScreen() {
    val client = (LocalContext.current.applicationContext as SampleApp).client
    val scope = rememberCoroutineScope()
    val attempts = remember { mutableStateListOf<Attempt>() }
    var isRunning by remember { mutableStateOf(false) }

    suspend fun send(call: Call) {
        isRunning = true
        try {
            val started = System.nanoTime()
            val outcome = withContext(Dispatchers.IO) { execute(client, call) }
            attempts.add(0, Attempt(call.title, call.method, outcome, (System.nanoTime() - started) / 1_000_000))
        } finally {
            isRunning = false
        }
    }

    TitledScreen("Network") {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            // Sequential rather than concurrent, so the plugin's list reads in the order
            // the buttons are listed instead of whatever finishes first.
            TextButton(
                onClick = { scope.launch { calls().forEach { send(it) } } },
                enabled = !isRunning,
                modifier = Modifier.padding(horizontal = 4.dp),
            ) { Text("Run every request", fontWeight = FontWeight.Medium) }
            SectionFooter("Open the Network plugin in Necto to watch these arrive.")

            SectionHeader("One at a time")
            calls().forEach { call ->
                LabeledRow(call.title, Modifier.clickable(enabled = !isRunning) { scope.launch { send(call) } }) {
                    Text(call.method, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            if (attempts.isNotEmpty()) {
                SectionHeader("Recent")
                attempts.forEach { attempt ->
                    LabeledRow("${attempt.method} ${attempt.title}", "${attempt.outcome} · ${attempt.milliseconds}ms")
                }
            }
        }
    }
}

private fun execute(client: OkHttpClient, call: Call): String {
    val body = call.body?.let { JSONObject(it).toString().toRequestBody("application/json; charset=utf-8".toMediaType()) }
    val request = Request.Builder()
        .url(call.url)
        .method(call.method, body)
        .header("Accept", "application/json")
        .build()
    return try {
        client.newCall(request).execute().use { response ->
            response.body?.bytes()
            response.code.toString()
        }
    } catch (error: Exception) {
        // The reason matters: a blocked host and a refused connection look the same in a
        // list that only says "failed".
        error.javaClass.simpleName.ifEmpty { "failed" }
    }
}
