// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import android.os.Bundle
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import im.toss.necto.sample.fixture.AccessibilityFixture
import im.toss.necto.sample.fixture.ControlFixture

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val content = ComposeView(this).apply { setContent { SampleTheme { RootView() } } }

        // A full-window view that takes no touches, on top of everything, as androidx.core's
        // ProtectionLayout puts one over an edge-to-edge window to shade the system bars.
        // It guards a hit-testing regression: UI Control once treated every visible view as
        // covering what lies below, so with this overlay every target, on every tab and the
        // Control tab's fixtures above all, disappeared. Touches pass through it, so Control
        // must look through it too.
        val protection = View(this)

        setContentView(
            FrameLayout(this).apply {
                addView(content, MATCH_PARENT, MATCH_PARENT)
                addView(protection, MATCH_PARENT, MATCH_PARENT)
            },
        )
    }
}

@Composable
private fun SampleTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(), content = content)
}

private enum class Tab(val title: String, val icon: ImageVector) {
    CONNECTION("Connection", Icons.Filled.Share),
    NETWORK("Network", Icons.AutoMirrored.Filled.List),
    CONTROL("Control", Icons.Filled.Build),
    ACCESSIBILITY("Accessibility", Icons.Filled.Face),
    ABOUT("About", Icons.Filled.Info),
}

@Composable
private fun RootView() {
    var tab by rememberSaveable { mutableStateOf(Tab.CONNECTION) }
    var sheet by rememberSaveable { mutableStateOf(false) }

    Box(Modifier.fillMaxSize()) {
        Scaffold(
            // Under a sheet, what it covers is gone for assistive technology too, as SwiftUI
            // makes a presented sheet modal. Control reads the same semantics, so covered
            // controls are neither offered nor read.
            modifier = if (sheet) Modifier.clearAndSetSemantics {} else Modifier,
            bottomBar = {
                NavigationBar {
                    Tab.entries.forEach { item ->
                        NavigationBarItem(
                            selected = tab == item,
                            onClick = { tab = item },
                            // No content description: the label is the tab's name, as on iOS.
                            icon = { Icon(item.icon, contentDescription = null) },
                            label = { Text(item.title) },
                        )
                    }
                }
            },
        ) { padding ->
            Box(Modifier.padding(padding).consumeWindowInsets(padding).imePadding()) {
                when (tab) {
                    Tab.CONNECTION -> ConnectionScreen()
                    Tab.NETWORK -> NetworkScreen()
                    Tab.CONTROL -> ControlFixture()
                    Tab.ACCESSIBILITY -> AccessibilityFixture(onOpenSheet = { sheet = true })
                    Tab.ABOUT -> AboutScreen()
                }
            }
        }

        if (sheet) {
            BackHandler { sheet = false }
            // Drawn in the activity's own window rather than a dialog's: UI Control acts on
            // one window, and an iOS sheet is part of the app's window as well.
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.32f))
                    .pointerInput(Unit) { detectTapGestures { sheet = false } },
            ) {
                Surface(
                    shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .fillMaxHeight(0.9f)
                        .pointerInput(Unit) { detectTapGestures { } },
                ) {
                    Box(contentAlignment = Alignment.Center) { Text("Accessibility Sheet") }
                }
            }
        }
    }
}
