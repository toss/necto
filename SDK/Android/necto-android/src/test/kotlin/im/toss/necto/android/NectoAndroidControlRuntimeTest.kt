// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.app.Activity
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.password
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoControlTarget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w360dp-h640dp")
class NectoAndroidControlRuntimeTest {
    private var activity: Activity? = null
    private val runtime = NectoAndroidControlRuntime { activity }

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    // MARK: Views

    @Test
    fun viewsAreListedTappedAndTypedInto() = runTest {
        var taps = 0
        val field = EditText(start()).apply { hint = "Name" }
        show(
            LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(Button(context).apply { text = "Save"; setOnClickListener { taps++ } })
                addView(field)
            },
        )

        val targets = runtime.snapshot()
        assertEquals("screen", targets.first().role)
        val save = targets.single { it.label == "Save" }
        assertEquals("button", save.role)
        assertEquals("textInput", targets.single { it.label == "Name" }.role)

        perform("tap", save)
        assertEquals(1, taps)

        perform("input", runtime.snapshot().single { it.label == "Name" }, "text" to jsonOf("necto"))
        assertEquals("necto", field.text.toString())
    }

    // MARK: Compose

    @Test
    fun composeElementsAreListedWithLabelsTagsAndValues() = runTest {
        start().compose {
            Column {
                BasicText("Increment", Modifier.testTag("increment").clickable {})
                BasicTextField("", {}, Modifier.testTag("name").semantics { contentDescription = "Name" })
                BasicTextField("secret", {}, Modifier.semantics { contentDescription = "Password"; password() })
                LazyColumn(Modifier.height(200.dp).testTag("list")) {
                    items(50) { BasicText("Row $it") }
                }
                BasicText("Not actionable")
            }
        }

        val targets = runtime.snapshot()
        val button = targets.single { it.identifier == "increment" }
        assertEquals("button", button.role)
        assertEquals("Increment", button.label)
        assertEquals(listOf("tap"), button.actions)

        val field = targets.single { it.identifier == "name" }
        assertEquals("textInput", field.role)
        assertEquals(listOf("tap", "input"), field.actions)
        assertEquals("", field.value)

        val password = targets.single { it.label == "Password" }
        assertTrue(password.isSecure)
        assertNull(password.value)

        assertEquals("scrollArea", targets.single { it.identifier == "list" }.role)
        assertTrue(targets.none { it.label == "Not actionable" })
    }

    @Test
    fun composeTapRunsTheClickHandler() = runTest {
        var count by mutableIntStateOf(0)
        start().compose {
            BasicText("Count $count", Modifier.testTag("increment").clickable { count++ })
        }

        val result = perform("tap", runtime.snapshot().single { it.identifier == "increment" })

        assertEquals(1, count)
        assertEquals(jsonOf("touch"), result["method"])
        assertEquals("Count 1", runtime.readAccessibility().single { it.identifier == "increment" }.label)
    }

    @Test
    fun composeInputReplacesAndAppendsThroughTheFieldState() = runTest {
        var text by mutableStateOf("old")
        start().compose {
            BasicTextField(text, { text = it }, Modifier.testTag("name"))
        }

        perform("input", runtime.snapshot().single { it.identifier == "name" }, "text" to jsonOf("necto"))
        assertEquals("necto", text)

        perform("input", runtime.snapshot().single { it.identifier == "name" }, "text" to jsonOf(" android"), "mode" to jsonOf("append"))
        assertEquals("necto android", text)
    }

    @Test
    fun composeListScrollsOnSwipe() = runTest {
        start().compose {
            LazyColumn(Modifier.height(200.dp).testTag("list")) {
                items(100) { BasicText("Row $it", Modifier.height(40.dp)) }
            }
        }
        assertTrue(labels().contains("Row 0"))

        perform("swipe", runtime.snapshot().single { it.identifier == "list" }, "direction" to jsonOf("up"))

        assertFalse(labels().contains("Row 0"))
    }

    // MARK: Hit testing

    @Test
    fun overlaysThatTakeNoTouchesDoNotHideComposeContent() = runTest {
        var count by mutableIntStateOf(0)
        val compose = ComposeView(start()).apply {
            setContent { BasicText("Increment", Modifier.testTag("increment").clickable { count++ }) }
        }
        // Like androidx.core's ProtectionLayout behind edge-to-edge system bars.
        val overlay = View(activity)
        show(stack(compose, overlay))

        perform("tap", runtime.snapshot().single { it.identifier == "increment" })

        assertEquals(1, count)
    }

    @Test
    fun overlaysThatTakeTouchesHideWhatIsBelow() = runTest {
        val compose = ComposeView(start()).apply {
            setContent { BasicText("Increment", Modifier.testTag("increment").clickable {}) }
        }
        val scrim = View(activity).apply { isClickable = true }
        show(stack(compose, scrim))

        assertTrue(runtime.snapshot().none { it.identifier == "increment" })
    }

    // MARK: Helpers

    private fun start(): ComponentActivity =
        Robolectric.buildActivity(ComponentActivity::class.java).setup().get().also { activity = it }

    private fun ComponentActivity.compose(content: @androidx.compose.runtime.Composable () -> Unit) {
        setContent { Column(Modifier.fillMaxSize()) { content() } }
        idle()
    }

    private fun show(view: View) {
        (activity as ComponentActivity).setContentView(view)
        idle()
    }

    private fun stack(vararg views: View): View = FrameLayout(activity!!).apply {
        views.forEach { addView(it, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT) }
    }

    private suspend fun perform(operation: String, target: NectoControlTarget, vararg fields: Pair<String, NectoJsonValue>): NectoJsonValue {
        val result = runtime.perform(operation, jsonObject("targetID" to jsonOf(target.id), *fields))
        idle()
        assertNotNull(result["dispatched"])
        return result
    }

    private suspend fun labels(): List<String> = runtime.readAccessibility().mapNotNull { it.label }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()
}
