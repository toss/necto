// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.plugins

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonArray
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** One reading of one thing, at one moment (milliseconds since the epoch). */
public data class NectoSample(val value: Double, val at: Long = System.currentTimeMillis())

/** Something worth watching over time, with the line it should stay on the right side of. */
public data class NectoMetric(
    val id: String,
    val title: String,
    /** Shown after the value: `MB`, `fps`, `%`. */
    val unit: String,
    val budget: Budget? = null,
) {
    public sealed class Budget {
        public abstract val limit: Double

        /** A ceiling, such as 80% CPU. */
        public data class AtMost(override val limit: Double) : Budget()

        /** A floor, such as 55 fps. */
        public data class AtLeast(override val limit: Double) : Budget()

        internal val isCeiling: Boolean get() = this is AtMost

        internal fun isExceededBy(value: Double): Boolean = when (this) {
            is AtMost -> value > limit
            is AtLeast -> value < limit
        }
    }
}

/** Somewhere to send readings. */
public interface NectoPerformanceReporting {
    public fun report(value: Double, metricID: String)
}

/** One batch produced by an optional sampler. `snapshot` is returned as-is. */
public data class NectoPerformanceReading(val values: Map<String, Double>, val snapshot: NectoJsonValue)

/** An optional source of automatic readings, such as the Android process sampler. */
public interface NectoPerformanceSampling {
    public val metrics: List<NectoMetric>
    public suspend fun start()
    public suspend fun stop()
    public suspend fun snapshot(): NectoPerformanceReading
    public suspend fun detail(): NectoJsonValue
}

/**
 * What the app is spending, read from Necto.
 *
 * ```kotlin
 * val performance = NectoPerformancePlugin(listOf(
 *     NectoMetric("frame", "Frame time", "ms", NectoMetric.Budget.AtMost(16.7)),
 * ))
 * NectoSDK.register(performance)
 * performance.report(12.0, "frame")
 * ```
 */
public class NectoPerformancePlugin(
    metrics: List<NectoMetric> = emptyList(),
    private val sampler: NectoPerformanceSampling? = null,
) : NectoPlugin, NectoPerformanceReporting {
    override val id: String = "performance-monitor"

    override val panel: NectoPluginPanel = NectoPanels.resource("performance-monitor")

    private val metrics: List<NectoMetric> =
        metrics + sampler?.metrics.orEmpty().filter { automatic -> metrics.none { it.id == automatic.id } }
    private val monitor = sampler?.let(::NectoPerformanceMonitor)
    private val lock = Any()
    private val samples = HashMap<String, ArrayDeque<NectoSample>>()
    private val listeners = NectoListeners()

    override fun register(necto: NectoRegistrar) {
        necto.handle("performance.metrics") {
            jsonObject("metrics" to jsonArray(metrics.map(::describe)))
        }

        necto.handle("performance.series") { input ->
            val limit = (input["limit"]?.numberValue ?: 120.0).toInt()
            val wanted = input["metricID"]?.stringValue
            val series = metrics.filter { wanted == null || it.id == wanted }.map { metric ->
                val taken = synchronized(lock) { samples[metric.id]?.toList().orEmpty().takeLast(limit) }
                jsonObject(
                    "metricID" to jsonOf(metric.id),
                    "samples" to jsonArray(taken.map(::encode)),
                    "latest" to (taken.lastOrNull()?.let { jsonOf(it.value) } ?: NectoJsonValue.Null),
                    "isOverBudget" to jsonOf(isOver(taken.lastOrNull()?.value, metric.budget)),
                )
            }
            jsonObject("series" to jsonArray(series))
        }

        necto.stream("performance.observe") { input, out ->
            val token = Any()
            val interval = (input["interval"]?.numberValue ?: 1.0).coerceIn(0.1, 60.0)
            listeners.hold(
                out,
                onStart = { monitor?.add(token, interval) { receive(it) } },
                onEnd = { monitor?.remove(token) },
            )
        }

        necto.handle("performance.snapshot") {
            val sampler = sampler ?: throw unavailable()
            val reading = sampler.snapshot()
            receive(reading)
            jsonObject("snapshot" to reading.snapshot)
        }

        necto.handle("performance.memory") {
            val sampler = sampler ?: throw unavailable()
            jsonObject("memory" to sampler.detail())
        }
    }

    /** Records one reading. A value for a metric that was never declared is dropped. */
    override fun report(value: Double, metricID: String) {
        val metric = metrics.firstOrNull { it.id == metricID } ?: return
        val sample = NectoSample(value)
        synchronized(lock) {
            val series = samples.getOrPut(metricID) { ArrayDeque() }
            series.addLast(sample)
            while (series.size > CAPACITY) series.removeFirst()
        }
        listeners.broadcast(
            jsonObject(
                "metricID" to jsonOf(metricID),
                "sample" to encode(sample),
                "isOverBudget" to jsonOf(isOver(value, metric.budget)),
            ),
        )
    }

    private fun receive(reading: NectoPerformanceReading) {
        for ((metricID, value) in reading.values) report(value, metricID)
    }

    private fun unavailable() = NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "Process metrics were not enabled")

    public companion object {
        /** About twenty minutes at one reading a second. */
        public const val CAPACITY: Int = 1200

        internal fun describe(metric: NectoMetric): NectoJsonValue {
            val fields = linkedMapOf(
                "id" to jsonOf(metric.id),
                "title" to jsonOf(metric.title),
                "unit" to jsonOf(metric.unit),
            )
            metric.budget?.let { budget ->
                fields["budget"] = jsonOf(budget.limit)
                fields["budgetKind"] = jsonOf(if (budget.isCeiling) "atMost" else "atLeast")
            }
            return jsonObject(fields)
        }

        internal fun encode(sample: NectoSample): NectoJsonValue =
            jsonObject("at" to jsonOf(sample.at), "value" to jsonOf(sample.value))

        internal fun isOver(value: Double?, budget: NectoMetric.Budget?): Boolean =
            value != null && budget != null && budget.isExceededBy(value)
    }
}

/**
 * Runs the sampler while at least one subscriber listens, at the first subscriber's
 * interval, and stops it with the last.
 */
private class NectoPerformanceMonitor(private val sampler: NectoPerformanceSampling) {
    private val mutex = Mutex()
    // A sampler belongs to the app, and a failure in it must never reach the app's
    // uncaught exception handler: the loop stops, and this is the last line of defense.
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default +
            CoroutineExceptionHandler { _, error -> System.err.println("Necto: the performance sampler failed: $error") },
    )
    private val subscriptions = LinkedHashMap<Any, Double>()
    private var receive: ((NectoPerformanceReading) -> Unit)? = null
    private var running: Job? = null

    suspend fun add(token: Any, interval: Double, receive: (NectoPerformanceReading) -> Unit) = mutex.withLock {
        subscriptions[token] = interval
        this.receive = receive
        if (running == null) start(interval, receive)
    }

    suspend fun remove(token: Any) = withContext(NonCancellable) {
        mutex.withLock {
            subscriptions.remove(token)
            if (subscriptions.isNotEmpty()) return@withLock
            running?.let {
                it.cancel()
                it.join()
            }
            running = null
        }
    }

    private fun start(interval: Double, receive: (NectoPerformanceReading) -> Unit) {
        running = scope.launch {
            try {
                sampler.start()
                while (isActive) {
                    receive(sampler.snapshot())
                    delay((interval * 1000).toLong())
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // Sampling stops; the app goes on. Subscribers see the stream go quiet.
                System.err.println("Necto: the performance sampler failed: $error")
            } finally {
                withContext(NonCancellable) { runCatching { sampler.stop() } }
            }
        }
    }
}
