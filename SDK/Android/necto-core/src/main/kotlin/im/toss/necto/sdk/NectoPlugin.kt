// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sdk

import im.toss.necto.model.NectoBridgeBinding
import im.toss.necto.model.NectoBridgeDescriptor
import im.toss.necto.model.NectoBridgeKind
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.NectoOperationKind
import im.toss.necto.model.NectoPanelArchive
import im.toss.necto.model.jsonObject
import java.io.File

/**
 * A bridge the app contributes to Necto: a name, and a chance to say what it answers.
 *
 * ```kotlin
 * class ThingsPlugin : NectoPlugin {
 *     override val id = "com.example.things"
 *
 *     override fun register(necto: NectoRegistrar) {
 *         necto.handle("things.list") { jsonObject("things" to jsonArray(…)) }
 *         necto.stream("things.observe") { _, out ->
 *             changes.collect { out.send(it) }
 *         }
 *     }
 * }
 * ```
 */
public interface NectoPlugin {
    /** Stable and unique within the app. Lowercase reverse-domain IDs are recommended. */
    public val id: String

    /** The plugin's own screen, when it ships one. It appears on the Mac when the app connects. */
    public val panel: NectoPluginPanel? get() = null

    /** Called once per successful registration. */
    public fun register(necto: NectoRegistrar)
}

/** Where a plugin's built panel comes from. Read once, when the plugin is registered. */
public fun interface NectoPluginPanel {
    public fun read(): NectoPanelArchive

    public companion object {
        /** A panel directory on disk. */
        public fun directory(root: File): NectoPluginPanel = NectoPluginPanel { NectoPanelArchive.read(root) }

        /**
         * A panel packaged as Java resources under [root], with a `files.txt` index that
         * lists each file's path relative to [root], one per line. Resource folders cannot
         * be listed portably on Android, so the index is what makes them readable.
         */
        public fun resources(root: String, classLoader: ClassLoader = NectoPluginPanel::class.java.classLoader!!): NectoPluginPanel =
            NectoPluginPanel {
                val base = root.trimEnd('/')
                val index = classLoader.getResourceAsStream("$base/files.txt")
                    ?: throw IllegalStateException("No panel index at $base/files.txt")
                val paths = index.bufferedReader().use { reader ->
                    reader.readLines().map(String::trim).filter { it.isNotEmpty() && !it.startsWith("#") }
                }
                NectoPanelArchive(paths.map { path ->
                    val bytes = classLoader.getResourceAsStream("$base/$path")?.use { it.readBytes() }
                        ?: throw IllegalStateException("The panel index lists $path, which is missing")
                    NectoPanelArchive.File(path, bytes)
                })
            }
    }
}

/** Where a stream handler sends what it has. */
public fun interface NectoOut {
    public suspend fun send(value: NectoJsonValue)
}

/**
 * Collects what a plugin answers. Only useful for the length of [NectoPlugin.register].
 */
public class NectoRegistrar internal constructor() {
    internal class Registration(val descriptor: NectoBridgeDescriptor, val body: Body)

    internal sealed class Body {
        class Once(val run: suspend (NectoJsonValue) -> NectoJsonValue) : Body()
        class Stream(val run: suspend (NectoJsonValue, NectoOut) -> Unit) : Body()
    }

    internal val registrations = LinkedHashMap<String, Registration>()
    internal var hasDuplicateContracts = false
        private set

    /**
     * Answers once. Whatever [body] returns is the answer; throwing [im.toss.necto.model.NectoBridgeError]
     * answers with that error.
     *
     * [name] is relative to `necto.device.`, which is also how a panel calls it:
     * `handle("things.list")` here is `necto.device.send("things.list")` there.
     * [version] counts breaking changes rather than releases.
     */
    public fun handle(
        name: String,
        version: Int = 1,
        inputSchema: NectoJsonValue = jsonObject(),
        outputSchema: NectoJsonValue = jsonObject(),
        body: suspend (input: NectoJsonValue) -> NectoJsonValue,
    ) {
        add(name, version, NectoOperationKind.ONCE, inputSchema, outputSchema, Body.Once(body))
    }

    /**
     * Answers as many times as it likes. Ends when [body] returns, or when the caller
     * stops listening: the coroutine running [body] is cancelled then.
     */
    public fun stream(
        name: String,
        version: Int = 1,
        inputSchema: NectoJsonValue = jsonObject(),
        outputSchema: NectoJsonValue = jsonObject(),
        body: suspend (input: NectoJsonValue, out: NectoOut) -> Unit,
    ) {
        add(name, version, NectoOperationKind.STREAM, inputSchema, outputSchema, Body.Stream(body))
    }

    private fun add(
        name: String,
        version: Int,
        kind: NectoOperationKind,
        inputSchema: NectoJsonValue,
        outputSchema: NectoJsonValue,
        body: Body,
    ) {
        val descriptor = NectoBridgeDescriptor(
            binding = NectoBridgeBinding(NectoBridgeKind.DEVICE.prefix + name, version),
            kind = kind,
            inputSchema = inputSchema,
            outputSchema = outputSchema,
        )
        if (registrations.containsKey(descriptor.identity)) {
            hasDuplicateContracts = true
            return
        }
        registrations[descriptor.identity] = Registration(descriptor, body)
    }
}
