// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample.fixture

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.scrollBy
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import im.toss.necto.sample.TitledScreen
import kotlinx.coroutines.launch

/**
 * The iOS SwiftUI fixture, in Compose: a counter, a disabled button, a text field,
 * a pushed detail, a sheet, an element with its own accessibility scroll action, and
 * enough rows to scroll.
 *
 * The sheet is drawn by the root, over the tab bar as an iOS sheet is; this screen only
 * asks for it through [onOpenSheet].
 */
@Composable
fun AccessibilityFixture(onOpenSheet: () -> Unit) {
    var route by rememberSaveable { mutableStateOf(ROOT) }
    var taps by rememberSaveable { mutableIntStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    // Outside the branch, so coming back from a detail keeps the scroll position.
    val scroll = remember { ScrollState(0) }

    BackHandler(enabled = route != ROOT) { route = ROOT }
    val back: @Composable () -> Unit = {
        IconButton(onClick = { route = ROOT }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
    }

    when (route) {
        DETAIL -> TitledScreen("Detail", navigationIcon = back) {
            Text("Accessibility Detail", modifier = Modifier.padding(16.dp))
        }
        CUSTOM_SCROLL -> TitledScreen("Custom scroll", navigationIcon = back) { AccessibleScrollFixture() }
        else -> TitledScreen("Accessibility") {
            Column(
                modifier = Modifier.fillMaxSize().verticalScroll(scroll).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text("Taps: $taps", modifier = Modifier.testTag("ax.status"))
                Button(onClick = { taps += 1 }, modifier = Modifier.testTag("ax.tap")) { Text("Count tap") }
                Button(onClick = { taps += 100 }, enabled = false) { Text("Disabled button") }
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text("Query") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("ax.query").semantics { contentDescription = "Query" },
                )
                TextButton(onClick = { route = DETAIL }) { Text("Open detail") }
                TextButton(onClick = onOpenSheet) { Text("Open sheet") }
                TextButton(onClick = { route = CUSTOM_SCROLL }) { Text("Custom scroll action") }
                Text("Read-only text")
                for (index in 1..80) {
                    TextButton(onClick = { taps = index }, modifier = Modifier.testTag("ax.row.$index")) { Text("Row $index") }
                }
            }
        }
    }
}

/**
 * A list that answers assistive scroll requests itself, a page of ten rows at a time,
 * as SwiftUI's `accessibilityScrollAction` does. Touch scrolling is untouched.
 */
@Composable
private fun AccessibleScrollFixture() {
    var page by rememberSaveable { mutableIntStateOf(0) }
    var requests by rememberSaveable { mutableIntStateOf(0) }
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize()) {
        Text("Scroll requests: $requests, page: $page", modifier = Modifier.padding(horizontal = 16.dp))
        LazyColumn(
            state = list,
            modifier = Modifier
                .fillMaxSize()
                // Outermost, so it replaces the list's own scroll action rather than joining it.
                .semantics {
                    contentDescription = "Custom scroll area"
                    scrollBy { x, y ->
                        requests += 1
                        val forward = y > 0 || (y == 0f && x > 0)
                        page = (page + if (forward) 1 else -1).coerceIn(0, 7)
                        scope.launch { list.scrollToItem(page * 10) }
                        true
                    }
                },
        ) {
            items(80) { index ->
                Text("Accessible row ${index + 1}", modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp))
            }
        }
    }
}

private const val ROOT = "root"
private const val DETAIL = "detail"
private const val CUSTOM_SCROLL = "customScroll"
