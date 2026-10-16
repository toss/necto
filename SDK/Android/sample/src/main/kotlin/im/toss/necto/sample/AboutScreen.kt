// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import im.toss.necto.sdk.NectoSDK

@Composable
fun AboutScreen() {
    TitledScreen("About") {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            SectionHeader("Necto")
            LabeledRow("SDK", NectoSDK.VERSION)
            LabeledRow("Protocol", "v${NectoSDK.protocolVersion}")

            Text(
                "This sample exists to verify a real connection. Keep it running and open Necto on the Mac.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp),
            )
        }
    }
}
