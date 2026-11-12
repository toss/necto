// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sdk

/**
 * Who this app is, as the handshake tells the host. The Android module reads it from
 * the `Context`; on a plain JVM (tests, desktop tools) it comes from system properties.
 */
public interface NectoAppIdentity {
    /** The Android package name. The handshake is refused when it is empty. */
    public val appBundleID: String
    public val appName: String
    public val appVersion: String
    public val deviceName: String
    public val osVersion: String

    /** PNG bytes of the launcher icon, or null. */
    public val appIcon: ByteArray? get() = null

    /**
     * The host keys simulator connections by this. Android apps are keyed by their ADB
     * serial instead, so they leave it null.
     */
    public val simulatorID: String? get() = null
}

/** The identity used when the app supplies none. Readable from system properties for tests. */
public object NectoJvmAppIdentity : NectoAppIdentity {
    override val appBundleID: String
        get() = System.getProperty("necto.appBundleID") ?: System.getenv("NECTO_APP_BUNDLE_ID") ?: ""
    override val appName: String get() = System.getProperty("necto.appName") ?: "Unknown"
    override val appVersion: String get() = System.getProperty("necto.appVersion") ?: ""
    override val deviceName: String
        get() = runCatching { java.net.InetAddress.getLocalHost().hostName }.getOrDefault("JVM")
    override val osVersion: String get() = "${System.getProperty("os.name")} ${System.getProperty("os.version")}"
    override val simulatorID: String? get() = System.getProperty("necto.simulatorID")
}
