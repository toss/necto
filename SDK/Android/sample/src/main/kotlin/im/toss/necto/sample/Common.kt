// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** A titled screen, as a NavigationStack with a navigation title is on iOS. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TitledScreen(
    title: String,
    navigationIcon: @Composable () -> Unit = {},
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(title, modifier = Modifier.semantics { heading() }) },
            navigationIcon = navigationIcon,
            actions = actions,
        )
        content()
    }
}

/** A list section header, like `Section("Status")`. */
@Composable
fun SectionHeader(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 24.dp, bottom = 8.dp),
    )
}

/** A section footer, like `Section { } footer: { Text(…) }`. */
@Composable
fun SectionFooter(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

/** A label with its value on the trailing edge, like `LabeledContent`. */
@Composable
fun LabeledRow(label: String, modifier: Modifier = Modifier, value: @Composable RowScope.() -> Unit) {
    Column(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, modifier = Modifier.weight(1f))
            value()
        }
        HorizontalDivider(Modifier.padding(start = 16.dp))
    }
}

@Composable
fun LabeledRow(label: String, value: String) {
    LabeledRow(label) { Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}
