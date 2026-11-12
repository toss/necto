// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample.fixture

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Typeface
import android.os.Build
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import im.toss.necto.sample.R

/**
 * The classic View half of the Control fixture, a line-for-line port of the iOS
 * `ControlFixtureController`. UIKit there, Views here: Control reads a View tree and a
 * Compose semantics tree by different paths, and both need a fixture.
 *
 * Identifiers are resource entry names (`res/values/ids.xml`), which is where UI Control
 * reads a View's identifier from, spelled exactly as the iOS accessibility identifiers.
 */
@SuppressLint("ViewConstructor", "SetTextI18n", "ClickableViewAccessibility", "UseSwitchCompatOrMaterialCode")
internal class ViewControlFixture(
    context: Context,
    private val isDetail: Boolean,
    private val onPush: () -> Unit,
) : LinearLayout(context) {
    private val statusLabel = TextView(context)
    private val inputStatusLabel = TextView(context)
    private val scrollView = ScrollView(context)
    private val contentStack = LinearLayout(context)
    private var taps = 0
    private var navigationTaps = 0
    private var trapTaps = 0
    private var gestureTaps = 0
    private val multiTap = MultiTapCounter { fingers, taps -> inputStatusLabel.text = gestureStatus(fingers, taps) }

    init {
        orientation = VERTICAL
        configureNavigation()
        configureLayout()
        addInputControls()
        addGestureTargets()
        addScrollableButtons()
        updateStatus()
    }

    /** The navigation bar of the iOS fixture: a title and one action. */
    private fun configureNavigation() {
        val bar = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(4), dp(8), dp(4))
        }
        val title = TextView(context).apply {
            text = if (isDetail) "Control Detail" else "Control"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            typeface = Typeface.DEFAULT_BOLD
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isAccessibilityHeading = true
        }
        val action = Button(context, null, android.R.attr.borderlessButtonStyle).apply {
            id = R.id.poc_nav
            text = "Nav action"
            isAllCaps = false
            setOnClickListener {
                navigationTaps += 1
                updateStatus()
            }
        }
        bar.addView(title, LayoutParams(0, WRAP_CONTENT, 1f))
        bar.addView(action, LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        addView(bar, LayoutParams(MATCH_PARENT, WRAP_CONTENT))
    }

    private fun configureLayout() {
        statusLabel.id = R.id.poc_status
        statusLabel.setPadding(dp(16), 0, dp(16), 0)
        scrollView.id = R.id.poc_scroll
        scrollView.contentDescription = "Fixture scroll area"
        contentStack.orientation = VERTICAL
        contentStack.setPadding(dp(16), dp(8), dp(16), dp(16))

        addView(statusLabel, LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        scrollView.addView(contentStack, LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        addView(scrollView, LayoutParams(MATCH_PARENT, 0, 1f))
    }

    private fun addInputControls() {
        addButton("Tap counter", R.id.poc_tap) { recordTap() }

        inputStatusLabel.text = "Input: (empty)"
        inputStatusLabel.id = R.id.poc_inputStatus
        contentStack.addView(inputStatusLabel)
        contentStack.addView(makeTextField("Search query", R.id.poc_query))
        contentStack.addView(makeTextField("Password", R.id.poc_password, isSecure = true))

        val notes = EditText(context).apply {
            id = R.id.poc_notes
            contentDescription = "Notes"
            minLines = 3
            maxLines = 3
            gravity = Gravity.TOP or Gravity.START
            onTextChanged { inputStatusLabel.text = "Notes: $it" }
        }
        contentStack.addView(notes, LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        // Not in the iOS fixture: Android's toggles report their state as a value.
        val toggle = Switch(context).apply {
            id = R.id.poc_switch
            text = "Fixture switch"
            setOnCheckedChangeListener { _, checked -> inputStatusLabel.text = "Switch: ${if (checked) "on" else "off"}" }
        }
        contentStack.addView(toggle, LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        if (!isDetail) addButton("Open detail", R.id.poc_push) { onPush() }
    }

    private fun makeTextField(label: String, id: Int, isSecure: Boolean = false): EditText = EditText(context).apply {
        this.id = id
        hint = label
        isSingleLine = true
        inputType = if (isSecure) {
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        } else {
            InputType.TYPE_CLASS_TEXT
        }
        onTextChanged { inputStatusLabel.text = if (isSecure) "Password edited" else "Input: $it" }
    }

    private fun addGestureTargets() {
        // A label that takes taps and says so, so it is a target; where the touch landed is
        // reported back, which is how a positioned tap is checked.
        val accessible = makeLabel("Accessible tap target", R.id.poc_gesture).apply {
            setOnClickListener { accessibleTapped(0.5f, 0.5f) } // Activation without a touch.
            setOnTouchListener { view, event ->
                if (event.actionMasked == MotionEvent.ACTION_UP) accessibleTapped(event.x / view.width, event.y / view.height)
                true
            }
        }
        contentStack.addView(accessible)

        val multi = makeLabel("Multi-tap target", R.id.poc_multitap).apply {
            setOnClickListener { inputStatusLabel.text = gestureStatus(1, 1) }
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> multiTap.down()
                    MotionEvent.ACTION_POINTER_DOWN -> multiTap.pointers(event.pointerCount)
                    MotionEvent.ACTION_UP -> multiTap.up()
                    MotionEvent.ACTION_CANCEL -> multiTap.cancel()
                }
                true
            }
        }
        contentStack.addView(multi)

        contentStack.addView(makeLabel("Read-only label (not a button)", R.id.poc_readonly))

        // Reacts to touches but tells assistive technology nothing, so it must not be
        // offered as a target: Control only acts on what the app declares.
        val trap = makeLabel("Non-accessible gesture label", R.id.poc_trap).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            setOnTouchListener { _, event ->
                if (event.actionMasked == MotionEvent.ACTION_UP) trapTapped()
                true
            }
        }
        contentStack.addView(trap)
    }

    private fun makeLabel(text: String, id: Int): TextView = TextView(context).apply {
        this.text = text
        this.id = id
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        setPadding(0, dp(12), 0, dp(12))
        layoutParams = LayoutParams(MATCH_PARENT, WRAP_CONTENT)
    }

    private fun addScrollableButtons() {
        for (index in 1..80) {
            // ids.xml declares poc.item.1 … poc.item.80; looked up by name to avoid 80 R references.
            @SuppressLint("DiscouragedApi")
            val id = resources.getIdentifier("poc.item.$index", "id", context.packageName)
            addButton("Item $index", id) { recordTap() }
        }
    }

    private fun addButton(title: String, id: Int, action: () -> Unit) {
        val button = Button(context).apply {
            this.id = id
            text = title
            isAllCaps = false
            setOnClickListener { action() }
        }
        contentStack.addView(button, LayoutParams(MATCH_PARENT, WRAP_CONTENT))
    }

    private fun recordTap() {
        taps += 1
        updateStatus()
    }

    private fun accessibleTapped(x: Float, y: Float) {
        gestureTaps += 1
        updateStatus()
        inputStatusLabel.text = positionStatus(x, y)
    }

    private fun trapTapped() {
        trapTaps += 1
        updateStatus()
    }

    private fun updateStatus() {
        statusLabel.text = fixtureStatus(taps, navigationTaps, trapTaps, gestureTaps)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun EditText.onTextChanged(block: (String) -> Unit) {
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) = block(s?.toString().orEmpty())
        })
    }
}
