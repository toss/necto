// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import im.toss.necto.android.NectoAndroid
import im.toss.necto.sdk.NectoSDK

/**
 * Shows what the SDK is doing, so a failed connection is visible on the device rather
 * than only in the Mac app.
 */
@Composable
fun ConnectionScreen() {
    // A StateFlow rather than a one-second poll: the SDK already says when it changes.
    val status by NectoSDK.status.collectAsState()
    val context = LocalContext.current

    TitledScreen("Connection") {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            SectionHeader("Status")
            LabeledRow("Necto") {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).background(indicator(status), CircleShape))
                    Text(describe(status), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            LabeledRow("Protocol", "v${NectoSDK.protocolVersion}")

            Spacer(Modifier.height(16.dp))
            // Release builds never start Necto, so there is nothing to stop or restart.
            TextButton(onClick = { NectoAndroid.stop() }, enabled = BuildConfig.DEBUG) { Text("Stop listening") }
            // The plugins registered at launch stay registered, so none are passed again.
            TextButton(onClick = { NectoAndroid.start(context, emptyList()) }, enabled = BuildConfig.DEBUG) {
                Text("Start listening")
            }
            SectionFooter(
                "Necto reaches this app through ADB, over USB on a device and the same way in an " +
                    "emulator. Run `script/android-connect` on the Mac to forward the app's private socket.",
            )
        }
    }
}

private fun indicator(status: NectoSDK.Status): Color = when (status) {
    is NectoSDK.Status.Connected -> Color(0xFF34C759)
    is NectoSDK.Status.Listening -> Color(0xFFFF9500)
    NectoSDK.Status.Stopped -> Color(0xFF8E8E93)
    is NectoSDK.Status.Failed -> Color(0xFFFF3B30)
}

private fun describe(status: NectoSDK.Status): String = when (status) {
    NectoSDK.Status.Stopped -> "Stopped"
    // The endpoint is a random socket name, which says nothing to a person.
    is NectoSDK.Status.Listening -> "Waiting for Necto"
    is NectoSDK.Status.Connected -> "Connected as ${status.appBundleID}"
    is NectoSDK.Status.Failed -> status.reason
}
