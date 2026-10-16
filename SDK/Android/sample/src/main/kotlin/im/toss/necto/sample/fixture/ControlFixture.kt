// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample.fixture

import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/**
 * The Control tab. iOS has one UIKit fixture here; Android has two toolkits that UI
 * Control reads by different paths, so the tab carries the same fixture twice and a
 * switch between them: **Compose** (semantics tree, test tags) and **Views** (View tree,
 * resource ids, hosted in an `AndroidView`). Only one is on screen at a time, so the
 * shared labels and identifiers never match twice.
 */
@Composable
fun ControlFixture() {
    var toolkit by rememberSaveable { mutableStateOf(COMPOSE) }

    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilterChip(
                selected = toolkit == COMPOSE,
                onClick = { toolkit = COMPOSE },
                label = { Text("Compose") },
                modifier = Modifier.testTag("control.compose"),
            )
            FilterChip(
                selected = toolkit == VIEWS,
                onClick = { toolkit = VIEWS },
                label = { Text("Views") },
                modifier = Modifier.testTag("control.views"),
            )
        }
        HorizontalDivider()
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (toolkit == COMPOSE) ComposeFixtureStack() else ViewFixtureStack()
        }
    }
}

/** Root and detail, as the iOS fixture's navigation controller pushes them. Back pops. */
@Composable
private fun ComposeFixtureStack() {
    var detail by rememberSaveable { mutableStateOf(false) }
    // Held here rather than inside the screen, so the root keeps its counts across a push.
    val root = rememberComposeFixtureState()
    BackHandler(enabled = detail) { detail = false }
    if (detail) {
        val state = remember { ComposeFixtureState() }
        ComposeControlFixture(state, isDetail = true, onPush = {}, onBack = { detail = false })
    } else {
        ComposeControlFixture(root, isDetail = false, onPush = { detail = true }, onBack = {})
    }
}

@Composable
private fun ViewFixtureStack() {
    var detail by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    // The root stays attached under the detail, hidden, as a pushed controller's parent
    // stays in its navigation stack. Hidden Views are not Control targets.
    val root = remember { ViewControlFixture(context, isDetail = false, onPush = { detail = true }) }
    BackHandler(enabled = detail) { detail = false }
    Box(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { root },
            update = { it.visibility = if (detail) View.GONE else View.VISIBLE },
            modifier = Modifier.fillMaxSize(),
        )
        if (detail) {
            AndroidView(
                factory = { ViewControlFixture(it, isDetail = true, onPush = {}) },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

private const val COMPOSE = "compose"
private const val VIEWS = "views"
