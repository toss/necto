// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sdk

import im.toss.necto.model.NectoProtocol
import im.toss.necto.transport.NectoListener
import kotlinx.coroutines.flow.StateFlow

/**
 * The entry point embedded in a connected app.
 *
 * Waits for Necto on a listener the platform supplies, answers the handshake, and carries
 * plugin messages in both directions. Every capability an app exposes arrives as a [NectoPlugin].
 *
 * On Android, use `NectoAndroid.start(context)`, which supplies the app's identity and
 * its private listener.
 */
public object NectoSDK {
    public const val VERSION: String = "0.1.0"

    public sealed class Status {
        public data object Stopped : Status()
        public data class Listening(val endpoint: String) : Status()
        public data class Connected(val appBundleID: String) : Status()
        public data class Failed(val reason: String) : Status()
    }

    private val runtime = NectoSdkRuntime()

    /** The current connection state; collect it for later transitions. */
    public val status: StateFlow<Status> get() = runtime.status

    /** Who this app says it is in the handshake. Set before [start]. */
    public var identity: NectoAppIdentity
        get() = runtime.identity
        set(value) {
            runtime.identity = value
        }

    /**
     * Adds a plugin, at any point. One added while a host is attached joins that session.
     * Returns false when the ID or a contract is already registered; unregister first to
     * replace one.
     */
    public fun register(plugin: NectoPlugin): Boolean = runtime.register(plugin)

    /** Takes a plugin away and tells any attached host that it now offers nothing. */
    public fun unregister(id: String) {
        runtime.unregister(id)
    }

    public val plugins: List<NectoPlugin> get() = runtime.plugins

    /**
     * Starts listening on what [listen] opens. Safe to call at app start up; it does not
     * block the caller. When [listen] throws, or the listener fails, it is called again
     * after a second.
     */
    public fun start(listen: () -> NectoListener) {
        runtime.start(listen)
    }

    public fun stop() {
        runtime.stop()
    }

    /** The wire protocol version this SDK speaks. */
    public val protocolVersion: Int get() = NectoProtocol.CURRENT_VERSION
}
