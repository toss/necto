// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.view.Choreographer
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoMetric
import im.toss.necto.plugins.NectoPerformanceReading
import im.toss.necto.plugins.NectoPerformanceSampling
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.roundToLong

/**
 * CPU, memory, frame rate and thread sampling for an Android process: the counterpart
 * of the iOS `NectoProcessMetrics`. Nothing runs until a panel observes performance.
 *
 * - `cpu`: process CPU time over wall time, summed across threads like iOS (can pass 100%).
 * - `memory`: total PSS, the closest Android analogue of the iOS physical footprint.
 * - `resident-memory` / `compressed-memory`: VmRSS and VmSwap (zram is compressed).
 * - `fps`: Choreographer frame callbacks per second while sampling, left out of a
 *   reading until the first full second has been counted.
 */
public class NectoAndroidProcessSampler(context: Context) : NectoPerformanceSampling {
    private val context = context.applicationContext

    override val metrics: List<NectoMetric> = listOf(
        NectoMetric("cpu", "CPU", "%", NectoMetric.Budget.AtMost(80.0)),
        NectoMetric("memory", "Memory", "MB"),
        NectoMetric("fps", "Frame rate", "fps", NectoMetric.Budget.AtLeast(55.0)),
        NectoMetric("threads", "Threads", ""),
        NectoMetric("resident-memory", "Resident memory", "MB"),
        NectoMetric("compressed-memory", "Compressed memory", "MB"),
        NectoMetric("java-heap", "Java heap", "MB"),
        NectoMetric("native-heap", "Native heap", "MB"),
    )

    private val frames = FrameRateMonitor()
    private val cpuLock = Any()
    private var lastCpuMillis = 0L
    private var lastWallMillis = 0L

    override suspend fun start() {
        withContext(Dispatchers.Main) { frames.start() }
    }

    override suspend fun stop() {
        withContext(Dispatchers.Main) { frames.stop() }
    }

    override suspend fun snapshot(): NectoPerformanceReading {
        val status = processStatus()
        val pss = withContext(Dispatchers.IO) { totalPssKilobytes() }
        val cpu = cpuPercent()
        val fps = withContext(Dispatchers.Main) { frames.framesPerSecond }

        val memory = megabytesFromKilobytes(pss)
        val resident = megabytesFromKilobytes(status["VmRSS"])
        val compressed = megabytesFromKilobytes(status["VmSwap"])
        val threads = status["Threads"]?.toDouble() ?: Thread.activeCount().toDouble()
        val runtime = Runtime.getRuntime()
        val javaHeap = megabytes(runtime.totalMemory() - runtime.freeMemory())
        val nativeHeap = megabytes(Debug.getNativeHeapAllocatedSize())

        return NectoPerformanceReading(
            values = buildMap {
                put("cpu", cpu)
                put("memory", memory)
                // No frame rate until a full second has been counted: a 0 would draw a
                // false drop and flag the budget on every panel that just opened.
                fps?.let { put("fps", it) }
                put("threads", threads)
                put("resident-memory", resident)
                put("compressed-memory", compressed)
                put("java-heap", javaHeap)
                put("native-heap", nativeHeap)
            },
            snapshot = jsonObject(
                "cpu" to jsonOf(cpu),
                "memoryMB" to jsonOf(memory),
                "fps" to jsonOf(fps ?: 0.0),
                "threads" to jsonOf(threads),
                "residentMemoryMB" to jsonOf(resident),
                "compressedMemoryMB" to jsonOf(compressed),
                "javaHeapMB" to jsonOf(javaHeap),
                "nativeHeapMB" to jsonOf(nativeHeap),
                "thermalState" to jsonOf(thermalState()),
                "timestamp" to jsonOf(System.currentTimeMillis()),
            ),
        )
    }

    override suspend fun detail(): NectoJsonValue {
        val status = processStatus()
        val info = withContext(Dispatchers.IO) { Debug.MemoryInfo().also(Debug::getMemoryInfo) }
        val runtime = Runtime.getRuntime()
        return jsonObject(
            "available" to jsonOf(true),
            "physicalFootprintMB" to jsonOf(megabytesFromKilobytes(info.totalPss.toLong())),
            "residentSizeMB" to jsonOf(megabytesFromKilobytes(status["VmRSS"])),
            "virtualSizeMB" to jsonOf(megabytesFromKilobytes(status["VmSize"])),
            "compressedMB" to jsonOf(megabytesFromKilobytes(status["VmSwap"])),
            "javaPssMB" to jsonOf(megabytesFromKilobytes(info.dalvikPss.toLong())),
            "nativePssMB" to jsonOf(megabytesFromKilobytes(info.nativePss.toLong())),
            "javaHeapMB" to jsonOf(megabytes(runtime.totalMemory() - runtime.freeMemory())),
            "javaHeapLimitMB" to jsonOf(megabytes(runtime.maxMemory())),
            "nativeHeapMB" to jsonOf(megabytes(Debug.getNativeHeapAllocatedSize())),
        )
    }

    /** The first reading after a pause measures from the previous one, so it may be coarse. */
    private fun cpuPercent(): Double = synchronized(cpuLock) {
        val cpu = Process.getElapsedCpuTime()
        val wall = SystemClock.elapsedRealtime()
        val result = if (lastWallMillis == 0L || wall <= lastWallMillis) {
            0.0
        } else {
            (cpu - lastCpuMillis).toDouble() / (wall - lastWallMillis) * 100
        }
        lastCpuMillis = cpu
        lastWallMillis = wall
        (result * 10).roundToLong() / 10.0
    }

    private fun totalPssKilobytes(): Long? = runCatching {
        Debug.MemoryInfo().also(Debug::getMemoryInfo).totalPss.toLong()
    }.getOrNull()

    /** `/proc/self/status` fields, values in kB where the kernel reports kB. */
    private fun processStatus(): Map<String, Long> = runCatching {
        File("/proc/self/status").readLines().mapNotNull { line ->
            val colon = line.indexOf(':')
            if (colon < 0) return@mapNotNull null
            val number = line.substring(colon + 1).trim().substringBefore(' ').toLongOrNull() ?: return@mapNotNull null
            line.substring(0, colon) to number
        }.toMap()
    }.getOrDefault(emptyMap())

    private fun thermalState(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "unknown"
        val power = context.getSystemService(PowerManager::class.java) ?: return "unknown"
        return when (power.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal"
            PowerManager.THERMAL_STATUS_LIGHT -> "fair"
            PowerManager.THERMAL_STATUS_MODERATE, PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            PowerManager.THERMAL_STATUS_CRITICAL, PowerManager.THERMAL_STATUS_EMERGENCY, PowerManager.THERMAL_STATUS_SHUTDOWN -> "critical"
            else -> "unknown"
        }
    }

    private fun megabytes(bytes: Long): Double = (bytes / 1_048_576.0 * 10).roundToLong() / 10.0

    private fun megabytesFromKilobytes(kilobytes: Long?): Double =
        kilobytes?.let { (it / 1024.0 * 10).roundToLong() / 10.0 } ?: 0.0
}

/** Counts frames on the main thread. Touched only from the main thread. */
internal class FrameRateMonitor : Choreographer.FrameCallback {
    private var running = false
    private var firstFrameNanos = 0L
    private var frames = 0
    /** Null until a full second of frames has been counted since [start]. */
    var framesPerSecond: Double? = null
        private set

    fun start() {
        stop()
        running = true
        Choreographer.getInstance().postFrameCallback(this)
    }

    fun stop() {
        running = false
        Choreographer.getInstance().removeFrameCallback(this)
        firstFrameNanos = 0
        frames = 0
        framesPerSecond = null
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!running) return
        if (firstFrameNanos == 0L) {
            firstFrameNanos = frameTimeNanos
        } else {
            frames++
            val elapsed = (frameTimeNanos - firstFrameNanos) / 1_000_000_000.0
            if (elapsed >= 1) {
                framesPerSecond = (frames / elapsed * 10).roundToLong() / 10.0
                frames = 0
                firstFrameNanos = frameTimeNanos
            }
        }
        Choreographer.getInstance().postFrameCallback(this)
    }
}
