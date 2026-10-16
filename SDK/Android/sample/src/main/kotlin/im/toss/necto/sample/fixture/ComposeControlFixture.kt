// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample.fixture

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.invisibleToUser
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import im.toss.necto.sample.TitledScreen

/** What one Compose fixture screen holds, kept outside it so the root survives a detail. */
internal class ComposeFixtureState {
    var taps by mutableIntStateOf(0)
    var navigationTaps by mutableIntStateOf(0)
    var trapTaps by mutableIntStateOf(0)
    var gestureTaps by mutableIntStateOf(0)
    var inputStatus by mutableStateOf("Input: (empty)")
    var query by mutableStateOf("")
    var password by mutableStateOf("")
    var notes by mutableStateOf("")
    var switchOn by mutableStateOf(false)
    val scroll = ScrollState(0)
    val multiTap = MultiTapCounter { fingers, taps -> inputStatus = gestureStatus(fingers, taps) }
}

/**
 * The Compose half of the Control fixture: the iOS UIKit fixture's elements, labels and
 * identifiers (as test tags), drawn with Compose. Every action Control offers is
 * covered: taps, positioned and multi-finger taps, text input into plain and secure
 * fields, a push and back, and a scroll area long enough to swipe.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
internal fun ComposeControlFixture(state: ComposeFixtureState, isDetail: Boolean, onPush: () -> Unit, onBack: () -> Unit) {
    TitledScreen(
        title = if (isDetail) "Control Detail" else "Control",
        navigationIcon = {
            if (isDetail) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
            }
        },
        actions = {
            TextButton(onClick = { state.navigationTaps += 1 }, modifier = Modifier.testTag("poc.nav")) { Text("Nav action") }
        },
    ) {
        Text(
            fixtureStatus(state.taps, state.navigationTaps, state.trapTaps, state.gestureTaps),
            modifier = Modifier.padding(horizontal = 16.dp).testTag("poc.status"),
        )
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .testTag("poc.scroll")
                .semantics { contentDescription = "Fixture scroll area" }
                .verticalScroll(state.scroll)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilledTonalButton(onClick = { state.taps += 1 }, modifier = Modifier.fillMaxWidth().testTag("poc.tap")) { Text("Tap counter") }

            Text(state.inputStatus, modifier = Modifier.testTag("poc.inputStatus"))
            OutlinedTextField(
                value = state.query,
                onValueChange = {
                    state.query = it
                    state.inputStatus = "Input: $it"
                },
                placeholder = { Text("Search query") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("poc.query").semantics { contentDescription = "Search query" },
            )
            OutlinedTextField(
                value = state.password,
                onValueChange = {
                    state.password = it
                    state.inputStatus = "Password edited"
                },
                placeholder = { Text("Password") },
                singleLine = true,
                // Marks the field as a password in semantics, so Control never reads its value.
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth().testTag("poc.password").semantics { contentDescription = "Password" },
            )
            OutlinedTextField(
                value = state.notes,
                onValueChange = {
                    state.notes = it
                    state.inputStatus = "Notes: $it"
                },
                minLines = 3,
                maxLines = 3,
                modifier = Modifier.fillMaxWidth().testTag("poc.notes").semantics { contentDescription = "Notes" },
            )
            // Not in the iOS fixture: Android's toggles report their state as a value.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("poc.switch")
                    .toggleable(value = state.switchOn, role = Role.Switch) {
                        state.switchOn = it
                        state.inputStatus = "Switch: ${if (it) "on" else "off"}"
                    }
                    .padding(vertical = 4.dp),
            ) {
                Text("Fixture switch", modifier = Modifier.weight(1f).padding(top = 12.dp))
                Switch(checked = state.switchOn, onCheckedChange = null)
            }

            if (!isDetail) {
                FilledTonalButton(onClick = onPush, modifier = Modifier.fillMaxWidth().testTag("poc.push")) { Text("Open detail") }
            }

            // A plain label that reacts to a touch where it lands. It declares a click so
            // assistive technology (and Control) knows it can be tapped; the position comes
            // from the pointer, so a positioned tap is reported back exactly.
            Text(
                "Accessible tap target",
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("poc.gesture")
                    .semantics {
                        onClick {
                            state.gestureTaps += 1
                            state.inputStatus = positionStatus(0.5f, 0.5f)
                            true
                        }
                    }
                    .pointerInput(Unit) {
                        detectTapGestures { offset ->
                            state.gestureTaps += 1
                            state.inputStatus = positionStatus(offset.x / size.width, offset.y / size.height)
                        }
                    }
                    .padding(vertical = 12.dp),
            )

            Text(
                "Multi-tap target",
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("poc.multitap")
                    .semantics {
                        onClick {
                            state.inputStatus = gestureStatus(1, 1)
                            true
                        }
                    }
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            state.multiTap.down()
                            do {
                                val event = awaitPointerEvent()
                                state.multiTap.pointers(event.changes.count { it.pressed })
                                event.changes.forEach { it.consume() }
                            } while (event.changes.any { it.pressed })
                            state.multiTap.up()
                        }
                    }
                    .padding(vertical = 12.dp),
            )

            Text("Read-only label (not a button)", modifier = Modifier.testTag("poc.readonly").padding(vertical = 12.dp))

            // Reacts to touches but tells assistive technology nothing, so it must not be
            // offered as a target: Control only acts on what the app declares.
            Text(
                "Non-accessible gesture label",
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("poc.trap")
                    .semantics { invisibleToUser() }
                    .pointerInput(Unit) { detectTapGestures { state.trapTaps += 1 } }
                    .padding(vertical = 12.dp),
            )

            for (index in 1..80) {
                FilledTonalButton(
                    onClick = { state.taps += 1 },
                    modifier = Modifier.fillMaxWidth().testTag("poc.item.$index"),
                ) { Text("Item $index") }
            }
            Spacer(Modifier.padding(8.dp))
        }
    }
}

@Composable
internal fun rememberComposeFixtureState(): ComposeFixtureState = remember { ComposeFixtureState() }
