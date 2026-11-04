// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.NectoPluginManifest
import im.toss.necto.sdk.NectoPluginPanel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PanelTests {
    @Test
    fun selectedPluginsCarryValidPanels() {
        for (id in listOf("event-log", "network-logger", "files", "control", "performance-monitor", "preferences")) {
            val archive = NectoPluginPanel.resources("necto/panels/$id").read()
            val manifest = NectoPluginManifest.fromJson(NectoJsonValue.parse(
                archive.files.single { it.path == "manifest.json" }.data.toString(Charsets.UTF_8),
            ))
            manifest.validate()
            assertEquals(id, manifest.id)
            assertTrue(manifest.requiresTarget)
            assertTrue(archive.files.any { it.path == "index.html" })
        }
    }
}
