// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.app.Activity
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.password
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoControlTarget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
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
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w360dp-h640dp")
class NectoAndroidControlRuntimeTest {
    private var activity: Activity? = null
    private var controller: ActivityController<ComponentActivity>? = null
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

    /** A tap cancelled while held must release the view, or it stays pressed and long-presses. */
    @Test
    fun aCancelledTapReleasesTheTouch() = runTest {
        val actions = mutableListOf<Int>()
        var longPressed = false
        val button = Button(start()).apply {
            text = "Hold"
            setOnTouchListener { _, event -> actions += event.actionMasked; false }
            setOnLongClickListener { longPressed = true; true }
        }
        show(button)
        val target = runtime.snapshot().single { it.label == "Hold" }

        val tap = launch { runtime.perform("tap", jsonObject("targetID" to jsonOf(target.id))) }
        runCurrent()
        assertEquals(listOf(MotionEvent.ACTION_DOWN), actions)
        tap.cancel()
        runCurrent()
        idle()

        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL), actions)
        assertFalse(button.isPressed)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(2))
        assertFalse(longPressed)
    }

    /** A swipe cancelled mid-drag must release the touch instead of leaving it down. */
    @Test
    fun aCancelledSwipeReleasesTheTouch() = runTest {
        val actions = mutableListOf<Int>()
        val area = View(start()).apply {
            setOnTouchListener { _, event -> actions += event.actionMasked; true }
        }
        show(area)
        val screen = runtime.snapshot().first { it.role == "screen" }

        val swipe = launch {
            runtime.perform("swipe", jsonObject("targetID" to jsonOf(screen.id), "direction" to jsonOf("up")))
        }
        runCurrent()
        assertEquals(listOf(MotionEvent.ACTION_DOWN), actions)
        swipe.cancel()
        runCurrent()
        idle()

        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL), actions)
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
        suspend fun label() = runtime.readAccessibility().single { it.identifier == "increment" }.label
        afterFrames { label() == "Count 1" }
        assertEquals("Count 1", label())
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

        afterFrames { !labels().contains("Row 0") }
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

    /** Inside one Compose host, a touch is refused where another element covers the target. */
    @Test
    fun composeElementsCoveredInsideTheirHostAreNotTouched() = runTest {
        var count by mutableIntStateOf(0)
        start().compose {
            Box(Modifier.fillMaxWidth().height(100.dp)) {
                Box(Modifier.fillMaxSize().testTag("wide").clickable { count++ })
                Box(Modifier.fillMaxHeight().fillMaxWidth(0.3f).align(Alignment.CenterEnd).testTag("edge").clickable {})
                Box(Modifier.fillMaxSize().testTag("hidden").clickable {})
            }
        }
        val targets = runtime.snapshot()
        assertTrue(targets.none { it.identifier == "wide" })
        assertTrue(targets.none { it.identifier == "edge" })
        assertNotNull(targets.singleOrNull { it.identifier == "hidden" })
    }

    @Test
    fun composeTouchesLandOnlyWhereTheTargetIsOnTop() = runTest {
        var count by mutableIntStateOf(0)
        start().compose {
            Box(Modifier.fillMaxWidth().height(100.dp)) {
                Box(Modifier.fillMaxSize().testTag("wide").clickable { count++ })
                Box(Modifier.fillMaxHeight().fillMaxWidth(0.3f).align(Alignment.CenterEnd).testTag("edge").clickable {})
            }
        }
        val wide = runtime.snapshot().single { it.identifier == "wide" }

        assertUnavailable { runtime.perform("tap", jsonObject("targetID" to jsonOf(wide.id), "position" to jsonObject("x" to jsonOf(0.9), "y" to jsonOf(0.5)))) }
        assertEquals(0, count)

        perform("tap", wide, "position" to jsonObject("x" to jsonOf(0.1), "y" to jsonOf(0.5)))
        assertEquals(1, count)
    }

    /** A clickable parent is not tapped where a clickable child inside it takes the tap. */
    @Test
    fun composeParentsAreNotTappedThroughTheirClickableChildren() = runTest {
        var parent by mutableIntStateOf(0)
        var child by mutableIntStateOf(0)
        fun ComponentActivity.row(childAlignment: Alignment) = compose {
            Box(Modifier.fillMaxWidth().height(100.dp).testTag("parent").clickable { parent++ }) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(0.3f).align(childAlignment).testTag("child").clickable { child++ })
            }
        }
        start().row(Alignment.CenterEnd)
        val target = runtime.snapshot().single { it.identifier == "parent" }

        assertUnavailable { runtime.perform("tap", jsonObject("targetID" to jsonOf(target.id), "position" to jsonObject("x" to jsonOf(0.9), "y" to jsonOf(0.5)))) }
        assertEquals(0, child)

        perform("tap", target, "position" to jsonObject("x" to jsonOf(0.1), "y" to jsonOf(0.5)))
        assertEquals(1, parent)

        start().row(Alignment.Center)
        assertTrue(runtime.snapshot().none { it.identifier == "parent" })
    }

    @Test
    fun viewParentsAreNotTappedThroughTheirClickableChildren() = runTest {
        var rowTaps = 0
        var innerTaps = 0
        val inner = Button(start()).apply { text = "Inner"; setOnClickListener { innerTaps++ } }
        show(
            FrameLayout(inner.context).apply {
                contentDescription = "Row"
                setOnClickListener { rowTaps++ }
                addView(inner, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.END))
            },
        )
        val row = runtime.snapshot().single { it.label == "Row" }

        assertUnavailable { runtime.perform("tap", jsonObject("targetID" to jsonOf(row.id), "position" to jsonObject("x" to jsonOf(0.98), "y" to jsonOf(0.5)))) }
        assertEquals(0, innerTaps)

        perform("tap", row, "position" to jsonObject("x" to jsonOf(0.1), "y" to jsonOf(0.5)))
        assertEquals(1, rowTaps)

        inner.layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER)
        idle()
        assertTrue(runtime.snapshot().none { it.label == "Row" })
    }

    /** While a dialog or another window holds input focus, the activity behind it is not acted on. */
    @Test
    fun nothingIsActedOnWhileAnotherWindowHasFocus() = runTest {
        var taps = 0
        show(Button(start()).apply { text = "Save"; setOnClickListener { taps++ } })
        val save = runtime.snapshot().single { it.label == "Save" }

        controller!!.windowFocusChanged(false)
        idle()

        assertUnavailable { runtime.perform("tap", jsonObject("targetID" to jsonOf(save.id))) }
        assertTrue(runtime.snapshot().isEmpty())
        assertEquals(0, taps)
    }

    /** A tap that opens a dialog stops a double tap before its second tap lands behind it. */
    @Test
    fun aDialogOpenedByTheFirstTapStopsTheSecond() = runTest {
        var taps = 0
        // On release, as a click would once the looper runs it.
        show(Button(start()).apply {
            text = "Confirm"
            setOnTouchListener { _, event ->
                if (event.actionMasked == MotionEvent.ACTION_UP) {
                    taps++
                    controller!!.windowFocusChanged(false)
                }
                false
            }
        })
        val confirm = runtime.snapshot().single { it.label == "Confirm" }

        assertUnavailable { runtime.perform("tap", jsonObject("targetID" to jsonOf(confirm.id), "tapCount" to jsonOf(2))) }
        assertEquals(1, taps)
    }

    // MARK: Helpers

    private fun start(): ComponentActivity =
        Robolectric.buildActivity(ComponentActivity::class.java).setup().windowFocusChanged(true)
            .also { controller = it }.get().also { activity = it }

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

    /**
     * Compose redraws on a frame, and Robolectric runs frames only as its clock moves, so a
     * read straight after an action can see the old text. Moves the clock a frame at a time
     * until [done], for at most a second.
     */
    private suspend fun afterFrames(done: suspend () -> Boolean) {
        repeat(60) {
            if (done()) return
            shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(16))
        }
    }

    /** Suspends rather than blocks: an action that wrongly goes ahead fails here instead of hanging. */
    private suspend fun assertUnavailable(block: suspend () -> Unit) {
        val error = try {
            block()
            null
        } catch (error: NectoBridgeError) {
            error
        }
        assertEquals(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, error?.code)
    }

    private suspend fun labels(): List<String> = runtime.readAccessibility().mapNotNull { it.label }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()
}
