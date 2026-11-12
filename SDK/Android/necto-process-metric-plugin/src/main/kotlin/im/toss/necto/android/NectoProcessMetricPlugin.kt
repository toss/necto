// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.content.Context
import im.toss.necto.plugins.NectoMetric
import im.toss.necto.plugins.NectoPerformancePlugin
import im.toss.necto.plugins.NectoPerformanceReporting
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar

/** Performance reporting with an opt-in Android process sampler. */
public class NectoProcessMetricPlugin(context: Context, metrics: List<NectoMetric> = emptyList()) :
    NectoPlugin, NectoPerformanceReporting {
    public val performance: NectoPerformancePlugin = NectoPerformancePlugin(metrics, NectoAndroidProcessSampler(context))
    override val id: String get() = performance.id
    override val panel: NectoPluginPanel get() = performance.panel
    override fun register(necto: NectoRegistrar) { performance.register(necto) }
    override fun report(value: Double, metricID: String) { performance.report(value, metricID) }
}
