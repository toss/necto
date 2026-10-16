// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.app.Activity
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.text.InputType
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.AbsSeekBar
import android.widget.Button
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoAccessibilityItem
import im.toss.necto.plugins.NectoControlGeometry
import im.toss.necto.plugins.NectoControlTarget
import im.toss.necto.plugins.NectoPoint
import im.toss.necto.plugins.NectoRect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.lang.ref.WeakReference
import java.util.IdentityHashMap
import java.util.UUID
import java.util.WeakHashMap

/**
 * UI Control for Android: discovers action targets in the foreground activity's window
 * and delivers synthetic MotionEvents and key events to it.
 *
 * Views are read from the View hierarchy. Jetpack Compose content, when the app has
 * Compose, is read from each host view's semantics tree, so its buttons, fields and
 * lists are targets of their own. Dialogs and popups live in other windows and are not
 * reached.
 */
internal class NectoAndroidControlRuntime(private val activity: () -> Activity?) {
    /** A View, or with [composeID] an element inside the Compose host [view]. */
    private class Target(
        val view: WeakReference<View>,
        val frame: NectoRect,
        val label: String?,
        val actions: List<String>,
        val composeID: Int? = null,
    )

    // Touched only on the main thread.
    private val targets = HashMap<String, Target>()
    private val identities = WeakHashMap<View, String>()
    private val composeIdentities = WeakHashMap<View, HashMap<Int, String>>()
    private var performing = false

    /**
     * Visible frames for the pass in progress. A pass hit-tests every candidate from the
     * root, so without this each view's frame was measured again for every other view.
     */
    private var frameCache: IdentityHashMap<View, NectoRect?>? = null

    suspend fun snapshot(): List<NectoControlTarget> = onMain { cachingFrames { discover() } }

    private fun discover(): List<NectoControlTarget> {
        targets.clear()
        val root = rootView() ?: return emptyList()
        if (performing) return emptyList()
        return entries(root).flatMap { (view, frame) ->
            if (view !== root && isComposeHost(view)) composeTargets(root, view) else listOfNotNull(viewTarget(root, view, frame))
        }
    }

    private fun viewTarget(root: View, view: View, frame: NectoRect): NectoControlTarget? {
        run {
            val actions = actions(view, root)
            if (actions.isEmpty() || !isHit(root, view, NectoPoint(frame.midX, frame.midY))) return null
            val id = identities.getOrPut(view) { UUID.randomUUID().toString().uppercase() }
            val label = label(view)
            targets[id] = Target(WeakReference(view), frame, label, actions)
            val secure = isSecure(view)
            return NectoControlTarget(
                id = id,
                role = when {
                    view === root -> "screen"
                    "input" in actions -> "textInput"
                    "swipe" in actions -> "scrollArea"
                    else -> "button"
                },
                label = label,
                identifier = identifier(view),
                frame = frame,
                actions = actions,
                value = if (secure) null else value(view),
                isSecure = secure,
            )
        }
    }

    /** The elements of a Compose host that a touch at their center would reach. */
    private fun composeTargets(root: View, host: View): List<NectoControlTarget> {
        val hostFrame = visibleFrame(host, root) ?: return emptyList()
        val ids = composeIdentities.getOrPut(host) { HashMap() }
        return NectoComposeSemantics.targets(host).mapNotNull { node ->
            val frame = node.frame.intersection(hostFrame) ?: return@mapNotNull null
            if (!isHit(root, host, NectoPoint(frame.midX, frame.midY))) return@mapNotNull null
            val id = ids.getOrPut(node.id) { UUID.randomUUID().toString().uppercase() }
            targets[id] = Target(WeakReference(host), frame, node.label, node.actions, node.id)
            NectoControlTarget(
                id = id,
                role = node.role,
                label = node.label,
                identifier = node.identifier,
                frame = frame,
                actions = node.actions,
                value = node.value,
                isSecure = node.isSecure,
            )
        }
    }

    /** The Compose element [target] stands for, if it is still there, unchanged and on top. */
    private fun currentComposeFrame(root: View, host: View, target: Target, operation: String): NectoRect {
        val stale = "The target changed. Refresh Control before acting."
        val hostFrame = visibleFrame(host, root) ?: throw unavailable(stale)
        val node = NectoComposeSemantics.find(host, target.composeID ?: throw unavailable(stale))
        if (node == null || operation !in node.actions || node.label != target.label) throw unavailable(stale)
        val frame = node.frame.intersection(hostFrame) ?: throw unavailable(stale)
        if (frame != target.frame) throw unavailable("The element moved. Refresh Control before acting.")
        return frame
    }

    suspend fun readAccessibility(): List<NectoAccessibilityItem> = onMain {
        val root = rootView() ?: return@onMain emptyList()
        readItems(root)
    }

    suspend fun perform(operation: String, input: NectoJsonValue): NectoJsonValue = onMain {
        if (performing) throw unavailable("Another action is in progress")
        val root = rootView()
        val id = input["targetID"]?.stringValue
        val target = id?.let { targets[it] }
        val view = target?.view?.get()
        val compose = target?.composeID != null
        if (root == null || target == null || view == null || operation !in target.actions ||
            entries(root).none { it.first === view } ||
            (!compose && (operation !in actions(view, root) || label(view) != target.label))
        ) {
            throw unavailable("The target changed. Refresh Control before acting.")
        }
        val current = if (compose) {
            currentComposeFrame(root, view, target, operation)
        } else {
            visibleFrame(view, root)?.also {
                if (it != target.frame) throw unavailable("The element moved. Refresh Control before acting.")
            } ?: throw unavailable("The target changed. Refresh Control before acting.")
        }
        val center = NectoPoint(current.midX, current.midY)
        val position = NectoControlGeometry.position(input["position"], current)
        if (!isHit(root, view, position ?: center)) {
            throw unavailable("The target is covered by another view. Refresh Control before acting.")
        }

        performing = true
        targets.clear()
        try {
            val before = readItems(root)
            val window = activity() ?: throw unavailable("The app is not in the foreground")
            val method = when (operation) {
                "tap" -> {
                    val fingers = input["touchCount"]?.numberValue ?: 1.0
                    val taps = input["tapCount"]?.numberValue ?: 1.0
                    if (fingers !in 1.0..5.0 || Math.rint(fingers) != fingers || taps !in 1.0..3.0 || Math.rint(taps) != taps) {
                        throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "Use 1–5 fingers and 1–3 taps")
                    }
                    // Spread contacts inside the visible target and verify every one before sending any.
                    val points = NectoControlGeometry.tapPoints(position ?: center, fingers.toInt(), current)
                    if (!points.all { isHit(root, view, it) }) {
                        throw unavailable("The target is covered by another view. Refresh Control before acting.")
                    }
                    repeat(taps.toInt()) { index ->
                        if (index > 0) delay(TAP_GAP_MS)
                        tap(window, points)
                    }
                    "touch"
                }
                "swipe" -> {
                    val ratio = input["distanceRatio"]?.numberValue ?: 0.6
                    val milliseconds = input["durationMs"]?.numberValue ?: 400.0
                    if (!ratio.isFinite() || ratio !in 0.1..0.9 || !milliseconds.isFinite() || milliseconds !in 100.0..2000.0) {
                        throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "Use distanceRatio 0.1–0.9 and durationMs 100–2000")
                    }
                    val direction = input["direction"]?.stringValue.orEmpty()
                    val (start, end) = if (position != null) {
                        position to NectoControlGeometry.swipe(position, direction, ratio, current)
                    } else {
                        val rect = current.insetBy(minOf(12.0, current.width / 10), minOf(12.0, current.height / 10))
                        val dx = rect.width * ratio / 2
                        val dy = rect.height * ratio / 2
                        val middle = NectoPoint(rect.midX, rect.midY)
                        when (direction) {
                            "up" -> middle.copy(y = middle.y + dy) to middle.copy(y = middle.y - dy)
                            "down" -> middle.copy(y = middle.y - dy) to middle.copy(y = middle.y + dy)
                            "left" -> middle.copy(x = middle.x + dx) to middle.copy(x = middle.x - dx)
                            "right" -> middle.copy(x = middle.x - dx) to middle.copy(x = middle.x + dx)
                            else -> throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "Choose up, down, left, or right")
                        }
                    }
                    if (!isHit(root, view, start)) {
                        throw unavailable("The target is covered by another view. Refresh Control before acting.")
                    }
                    drag(window, start, end, milliseconds.toLong())
                    "touch"
                }
                "back" -> {
                    // The system back key, as the navigation bar sends it. The app may ignore it at the root.
                    val now = SystemClock.uptimeMillis()
                    window.dispatchKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK, 0))
                    window.dispatchKeyEvent(KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK, 0))
                    "backKey"
                }
                "input" -> {
                    val text = input["text"]?.stringValue
                    if (compose) {
                        val mode = input["mode"]?.stringValue ?: "replace"
                        if (text == null) throw unavailable("This target does not support text input")
                        if (mode != "replace" && mode != "append") {
                            throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "Choose replace or append")
                        }
                        // A tap focuses the field and brings up the keyboard, as a person would.
                        tap(window, listOf(center))
                        delay(FOCUS_DELAY_MS)
                        val id = target.composeID ?: throw unavailable("The target changed. Refresh Control before acting.")
                        if (!NectoComposeSemantics.setText(view, id, text, append = mode == "append")) {
                            throw unavailable("The text field did not accept the text. Refresh Control before acting.")
                        }
                        return@onMain finish(root, before, "textInput")
                    }
                    val editor = view as? TextView
                    if (text == null || editor == null || !editor.isEditableField()) {
                        throw unavailable("This target does not support text input")
                    }
                    val mode = input["mode"]?.stringValue ?: "replace"
                    if (mode != "replace" && mode != "append") {
                        throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "Choose replace or append")
                    }
                    tap(window, listOf(center))
                    delay(FOCUS_DELAY_MS)
                    if (!editor.hasFocus()) editor.requestFocus()
                    if (!editor.hasFocus() || editor.rootView !== root) {
                        throw unavailable("The text field did not receive focus. Refresh Control before acting.")
                    }
                    // Through the Editable, so TextWatchers and input filters see the change.
                    val editable = editor.editableText ?: throw unavailable("The text field did not provide an editable range")
                    if (mode == "replace") editable.replace(0, editable.length, text) else editable.append(text)
                    (editor as? EditText)?.setSelection(editor.length())
                    "textInput"
                }
                else -> throw unavailable("This operation is not supported")
            }
            finish(root, before, method)
        } finally {
            performing = false
        }
    }

    private suspend fun finish(root: View, before: List<NectoAccessibilityItem>, method: String): NectoJsonValue {
        delay(SETTLE_MS)
        return jsonObject(
            "dispatched" to jsonOf(true),
            "method" to jsonOf(method),
            "contentChanged" to jsonOf(before != (rootView()?.let(::readItems) ?: emptyList<NectoAccessibilityItem>())),
        )
    }

    // MARK: Discovery

    private fun rootView(): View? = activity()?.window?.decorView?.takeIf { it.isAttachedToWindow }

    /** Every visible view with its visible frame, in drawing order. */
    private fun entries(root: View): List<Pair<View, NectoRect>> {
        val result = ArrayList<Pair<View, NectoRect>>()
        fun walk(view: View) {
            if (!isVisible(view)) return
            if (isHiddenFromAccessibility(view)) return
            val frame = visibleFrame(view, root)
            if (frame != null && frame.width > 1 && frame.height > 1) result += view to frame
            if (view is ViewGroup) for (index in 0 until view.childCount) walk(view.getChildAt(index))
        }
        walk(root)
        return result
    }

    private fun isComposeHost(view: View): Boolean = hasCompose && NectoComposeSemantics.isHost(view)

    private fun actions(view: View, root: View): List<String> {
        if (!view.isEnabled) return emptyList()
        if (view === root) return listOf("tap", "swipe", "back")
        if (view is TextView && view.isEditableField()) return listOf("tap", "input")
        if (isScrollable(view)) return listOf("swipe")
        if (view.isClickable || view.isLongClickable) return listOf("tap")
        return emptyList()
    }

    private fun isScrollable(view: View): Boolean =
        view is ScrollView || view is HorizontalScrollView || view is AbsListView ||
            view.javaClass.name.let { it.endsWith("RecyclerView") || it.endsWith("ViewPager") || it.endsWith("NestedScrollView") } ||
            (view.isScrollContainer && (view.canScrollVertically(1) || view.canScrollVertically(-1) || view.canScrollHorizontally(1) || view.canScrollHorizontally(-1)))

    private fun TextView.isEditableField(): Boolean = this is EditText || onCheckIsTextEditor()

    private fun isSecure(view: View): Boolean {
        val field = view as? TextView ?: return false
        val variation = field.inputType and (InputType.TYPE_MASK_CLASS or InputType.TYPE_MASK_VARIATION)
        return variation == (InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD) ||
            variation == (InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD) ||
            variation == (InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD) ||
            variation == (InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD)
    }

    /** The content description, else the text, else the text of a clickable group's children. */
    private fun label(view: View): String? {
        view.contentDescription?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        if (view is EditText) return view.hint?.toString()?.takeIf { it.isNotBlank() }
        if (view is TextView) return view.text?.toString()?.takeIf { it.isNotBlank() }
        if (view is ViewGroup && (view.isClickable || view.isLongClickable)) {
            val parts = ArrayList<String>()
            fun collect(child: View) {
                if (!isVisible(child)) return
                val own = child.contentDescription?.toString()?.takeIf { it.isNotBlank() }
                    ?: (child as? TextView)?.takeIf { it !is EditText }?.text?.toString()?.takeIf { it.isNotBlank() }
                if (own != null) {
                    parts += own
                    return
                }
                if (child is ViewGroup) for (index in 0 until child.childCount) collect(child.getChildAt(index))
            }
            for (index in 0 until view.childCount) collect(view.getChildAt(index))
            return parts.joinToString(", ").takeIf { it.isNotEmpty() }
        }
        return null
    }

    private fun value(view: View): String? = when (view) {
        is EditText -> view.text?.toString()
        is CompoundButton -> if (view.isChecked) "1" else "0"
        is ProgressBar -> view.progress.toString()
        else -> null
    }

    /** The resource entry name, such as `login_button`, when the view has an id. */
    private fun identifier(view: View): String? {
        if (view.id == View.NO_ID) return null
        return runCatching { view.resources.getResourceEntryName(view.id) }.getOrNull()
    }

    private fun readItems(root: View): List<NectoAccessibilityItem> = cachingFrames {
        val items = ArrayList<NectoAccessibilityItem>()
        fun walk(view: View) {
            if (!isVisible(view) || isHiddenFromAccessibility(view)) return
            val frame = visibleFrame(view, root)
            val secure = isSecure(view)
            val label = if (view is ViewGroup) view.contentDescription?.toString()?.takeIf { it.isNotBlank() } else label(view)
            val value = if (secure) null else value(view)
            val identifier = identifier(view)
            val meaningful = label != null || value != null || (identifier != null && view !is ViewGroup)
            if (frame != null && frame.width > 1 && frame.height > 1 && meaningful &&
                isHit(root, view, NectoPoint(frame.midX, frame.midY))
            ) {
                items += NectoAccessibilityItem(role(view), label, identifier, value, secure)
            }
            if (frame != null && isComposeHost(view)) {
                items += NectoComposeSemantics.items(view)
            }
            // Secure fields own their descendants.
            if (!secure && view is ViewGroup) for (index in 0 until view.childCount) walk(view.getChildAt(index))
        }
        walk(root)
        items
    }

    private fun role(view: View): String = when {
        view is TextView && view.isEditableField() -> "textInput"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && view.isAccessibilityHeading -> "heading"
        view is AbsSeekBar -> "adjustable"
        view is Button || view is CompoundButton || view.isClickable -> "button"
        view is ImageView -> "image"
        view is TextView -> "text"
        else -> "element"
    }

    // MARK: Geometry

    private fun isVisible(view: View): Boolean =
        view.visibility == View.VISIBLE && view.alpha >= 0.01f && view.isShown

    private fun isHiddenFromAccessibility(view: View): Boolean =
        view.importantForAccessibility == View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS

    /**
     * The visible part of [view], clipped by its ancestors, in pixels. Global visible
     * rects are relative to the window's root view, which is also the space
     * `Activity.dispatchTouchEvent` reads touches in.
     */
    @Suppress("UNUSED_PARAMETER")
    private fun visibleFrame(view: View, root: View): NectoRect? {
        val cache = frameCache ?: return measureFrame(view)
        return if (cache.containsKey(view)) cache[view] else measureFrame(view).also { cache[view] = it }
    }

    /** Runs [block] with frames measured once per view, unless a pass is already caching. */
    private inline fun <T> cachingFrames(block: () -> T): T {
        if (frameCache != null) return block()
        frameCache = IdentityHashMap()
        try {
            return block()
        } finally {
            frameCache = null
        }
    }

    private fun measureFrame(view: View): NectoRect? {
        val rect = Rect()
        if (!view.getGlobalVisibleRect(rect)) return null
        return NectoRect(rect.left.toDouble(), rect.top.toDouble(), rect.width().toDouble(), rect.height().toDouble())
    }

    /**
     * Whether a touch at [point] reaches [view]: the topmost view under the point that
     * takes touches must be the view itself, inside it, or one of its ancestors.
     */
    private fun isHit(root: View, view: View, point: NectoPoint): Boolean {
        val hit = hitTest(root, root, point) ?: return false
        return hit === view || hit.isDescendantOf(view) || view.isDescendantOf(hit)
    }

    /**
     * The view a touch at [point] would land on. Like touch dispatch, a view that takes no
     * touches lets them through to what lies below it, so a full-window overlay such as
     * the system bar protection of edge-to-edge does not hide the content under it.
     */
    private fun hitTest(root: View, view: View, point: NectoPoint): View? {
        if (!isVisible(view)) return null
        val frame = visibleFrame(view, root) ?: return null
        if (point.x < frame.minX || point.x >= frame.maxX || point.y < frame.minY || point.y >= frame.maxY) return null
        if (view is ViewGroup) {
            // Later children draw on top; elevation is ignored, as most layouts follow order.
            for (index in view.childCount - 1 downTo 0) {
                hitTest(root, view.getChildAt(index), point)?.let { return it }
            }
        }
        return view.takeIf { it === root || takesTouches(it) }
    }

    private fun takesTouches(view: View): Boolean =
        view.isClickable || view.isLongClickable ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && view.isContextClickable) ||
            (view is TextView && view.isEditableField()) || isScrollable(view) || isComposeHost(view)

    private fun View.isDescendantOf(ancestor: View): Boolean {
        var parent = parent
        while (parent is View) {
            if (parent === ancestor) return true
            parent = parent.parent
        }
        return false
    }

    // MARK: Delivery

    /** One tap with every contact down together, then up together. */
    private suspend fun tap(activity: Activity, points: List<NectoPoint>) {
        val downTime = SystemClock.uptimeMillis()
        points.indices.forEach { count ->
            val action = if (count == 0) MotionEvent.ACTION_DOWN else pointerAction(MotionEvent.ACTION_POINTER_DOWN, count)
            dispatch(activity, downTime, action, points.take(count + 1))
        }
        delay(TAP_HOLD_MS)
        for (count in points.size downTo 1) {
            val action = if (count == 1) MotionEvent.ACTION_UP else pointerAction(MotionEvent.ACTION_POINTER_UP, count - 1)
            dispatch(activity, downTime, action, points.take(count))
        }
    }

    /** A single finger moving from [start] to [end], one move per frame. */
    private suspend fun drag(activity: Activity, start: NectoPoint, end: NectoPoint, durationMs: Long) {
        val downTime = SystemClock.uptimeMillis()
        dispatch(activity, downTime, MotionEvent.ACTION_DOWN, listOf(start))
        val steps = maxOf(2, (durationMs / FRAME_MS).toInt())
        for (step in 1..steps) {
            delay(FRAME_MS)
            val fraction = step.toDouble() / steps
            val point = NectoPoint(start.x + (end.x - start.x) * fraction, start.y + (end.y - start.y) * fraction)
            dispatch(activity, downTime, MotionEvent.ACTION_MOVE, listOf(point))
        }
        dispatch(activity, downTime, MotionEvent.ACTION_UP, listOf(end))
    }

    private fun pointerAction(action: Int, index: Int): Int = action or (index shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)

    private fun dispatch(activity: Activity, downTime: Long, action: Int, points: List<NectoPoint>) {
        val properties = Array(points.size) { index ->
            MotionEvent.PointerProperties().apply {
                id = index
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coordinates = Array(points.size) { index ->
            MotionEvent.PointerCoords().apply {
                x = points[index].x.toFloat()
                y = points[index].y.toFloat()
                pressure = 1f
                size = 1f
            }
        }
        val event = MotionEvent.obtain(
            downTime, SystemClock.uptimeMillis(), action, points.size, properties, coordinates,
            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
        )
        try {
            activity.dispatchTouchEvent(event)
        } finally {
            event.recycle()
        }
    }

    /** The overlap of two frames, or null when they do not overlap by more than a pixel. */
    private fun NectoRect.intersection(other: NectoRect): NectoRect? {
        val left = maxOf(minX, other.minX)
        val top = maxOf(minY, other.minY)
        val right = minOf(maxX, other.maxX)
        val bottom = minOf(maxY, other.maxY)
        if (right - left <= 1 || bottom - top <= 1) return null
        return NectoRect(left, top, right - left, bottom - top)
    }

    private fun unavailable(message: String) = NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, message)

    private suspend fun <T> onMain(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }

    private companion object {
        /** Checked by name, so apps without Compose never load [NectoComposeSemantics]. */
        val hasCompose: Boolean by lazy {
            runCatching { Class.forName("androidx.compose.ui.platform.ViewRootForTest") }.isSuccess
        }

        const val TAP_HOLD_MS = 50L
        const val TAP_GAP_MS = 120L
        const val FOCUS_DELAY_MS = 250L
        const val SETTLE_MS = 600L
        const val FRAME_MS = 16L
    }
}
