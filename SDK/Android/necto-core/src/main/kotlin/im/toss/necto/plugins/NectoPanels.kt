// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import im.toss.necto.sdk.NectoPluginPanel

/**
 * The panels Necto ships, packaged as Java resources under `necto/panels/<id>` with a
 * generated `files.txt` index. They are the iOS SDK's web panels, unchanged apart
 * from the manifests of Android-specific plugins.
 */
public object NectoPanels {
    public const val ROOT: String = "necto/panels"

    public fun resource(id: String): NectoPluginPanel =
        NectoPluginPanel.resources("$ROOT/$id", NectoPanels::class.java.classLoader!!)
}
