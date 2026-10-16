// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.view.View
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.AnnotatedString
import im.toss.necto.plugins.NectoAccessibilityItem
import im.toss.necto.plugins.NectoRect

/**
 * Reads Jetpack Compose content through its semantics tree, the same tree TalkBack and
 * Compose UI tests read, so each element inside a Compose host view becomes its own
 * target.
 *
 * Compose is an optional dependency. Only call into this object after checking that
 * the app has Compose on its classpath; loading it otherwise fails.
 */
internal object NectoComposeSemantics {
    /** One element of a Compose host, in window pixels like View frames. */
    class Node(
        val id: Int,
        val frame: NectoRect,
        val role: String,
        val label: String?,
        val identifier: String?,
        val value: String?,
        val isSecure: Boolean,
        val actions: List<String>,
    )

    fun isHost(view: View): Boolean = view is ViewRootForTest

    /** Every element that can be tapped, typed into or scrolled, in drawing order. */
    fun targets(host: View): List<Node> = walk(host).filter { it.actions.isNotEmpty() }

    /** Every element with something to read: a label, a value or a test tag. */
    fun items(host: View): List<NectoAccessibilityItem> = walk(host)
        .filter { it.label != null || it.value != null || it.identifier != null }
        .map { NectoAccessibilityItem(it.role, it.label, it.identifier, it.value, it.isSecure) }

    fun find(host: View, id: Int): Node? = walk(host).firstOrNull { it.id == id }

    /**
     * Sets a text field's text through its SetText semantics action, which goes through
     * the field's own state, so `onValueChange` sees it. Returns false when the field
     * offers no such action.
     */
    fun setText(host: View, id: Int, text: String, append: Boolean): Boolean {
        val node = semanticsNode(host, id) ?: return false
        val action = node.config.getOrNull(SemanticsActions.SetText)?.action ?: return false
        val current = node.config.getOrNull(SemanticsProperties.EditableText)?.text.orEmpty()
        return action(AnnotatedString(if (append) current + text else text))
    }

    // MARK: Tree

    private fun root(host: View): SemanticsNode? =
        (host as? ViewRootForTest)?.semanticsOwner?.rootSemanticsNode

    private fun semanticsNode(host: View, id: Int): SemanticsNode? {
        fun search(node: SemanticsNode): SemanticsNode? {
            if (node.id == id) return node
            node.children.forEach { child -> search(child)?.let { return it } }
            return null
        }
        return root(host)?.let(::search)
    }

    /** Merged nodes, so a button's label includes the text inside it, as TalkBack reads it. */
    private fun walk(host: View): List<Node> {
        val root = root(host) ?: return emptyList()
        val result = ArrayList<Node>()
        fun visit(node: SemanticsNode, isRoot: Boolean) {
            val config = node.config
            if (config.contains(SemanticsProperties.InvisibleToUser)) return
            if (!isRoot) node(node)?.let { result += it }
            // A password field owns its descendants, like a secure View.
            if (!config.contains(SemanticsProperties.Password)) node.children.forEach { visit(it, false) }
        }
        visit(root, true)
        return result
    }

    private fun node(node: SemanticsNode): Node? {
        val bounds = node.boundsInWindow
        if (bounds.width <= 1f || bounds.height <= 1f) return null
        val config = node.config
        val enabled = !config.contains(SemanticsProperties.Disabled)
        val editable = config.contains(SemanticsActions.SetText)
        val actions = when {
            !enabled -> emptyList()
            editable -> listOf("tap", "input")
            config.contains(SemanticsActions.ScrollBy) -> listOf("swipe")
            config.contains(SemanticsActions.OnClick) || config.contains(SemanticsActions.OnLongClick) -> listOf("tap")
            else -> emptyList()
        }
        val secure = config.contains(SemanticsProperties.Password)
        return Node(
            id = node.id,
            // Whole pixels, so a frame read twice compares equal.
            frame = NectoRect(
                bounds.left.toInt().toDouble(),
                bounds.top.toInt().toDouble(),
                (bounds.right.toInt() - bounds.left.toInt()).toDouble(),
                (bounds.bottom.toInt() - bounds.top.toInt()).toDouble(),
            ),
            role = role(node, editable, actions),
            label = label(node),
            identifier = config.getOrNull(SemanticsProperties.TestTag)?.takeIf { it.isNotBlank() },
            value = if (secure) null else value(node, editable),
            isSecure = secure,
            actions = actions,
        )
    }

    /** The content description, else the text: what TalkBack would say first. */
    private fun label(node: SemanticsNode): String? {
        val config = node.config
        config.getOrNull(SemanticsProperties.ContentDescription)
            ?.filter { it.isNotBlank() }?.takeIf { it.isNotEmpty() }
            ?.let { return it.joinToString(", ") }
        return config.getOrNull(SemanticsProperties.Text)
            ?.map { it.text }?.filter { it.isNotBlank() }?.takeIf { it.isNotEmpty() }
            ?.joinToString(", ")
    }

    private fun value(node: SemanticsNode, editable: Boolean): String? {
        val config = node.config
        if (editable) return config.getOrNull(SemanticsProperties.EditableText)?.text
        config.getOrNull(SemanticsProperties.ToggleableState)?.let { return if (it == ToggleableState.On) "1" else "0" }
        config.getOrNull(SemanticsProperties.Selected)?.let { return if (it) "1" else "0" }
        config.getOrNull(SemanticsProperties.ProgressBarRangeInfo)?.let { return it.current.toString() }
        return null
    }

    private fun role(node: SemanticsNode, editable: Boolean, actions: List<String>): String {
        val config = node.config
        if (editable) return "textInput"
        if (config.contains(SemanticsProperties.Heading)) return "heading"
        return when (config.getOrNull(SemanticsProperties.Role)) {
            Role.Button, Role.Checkbox, Role.Switch, Role.RadioButton, Role.Tab, Role.DropdownList -> "button"
            Role.Image -> "image"
            else -> when {
                "swipe" in actions -> "scrollArea"
                "tap" in actions -> "button"
                config.contains(SemanticsProperties.ProgressBarRangeInfo) &&
                    config.contains(SemanticsActions.SetProgress) -> "adjustable"
                config.contains(SemanticsProperties.Text) -> "text"
                else -> "element"
            }
        }
    }
}
