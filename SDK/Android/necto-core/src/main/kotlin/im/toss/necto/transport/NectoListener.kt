// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.transport

/**
 * Where an app waits for Necto. The socket roles are the opposite of the protocol
 * roles: the app listens and the host connects, even though the host drives the session.
 *
 * The SDK knows nothing about the socket underneath. On Android it is a private Unix
 * socket the host reaches through ADB; tests use loopback TCP.
 */
public interface NectoListener {
    /** A description of where the listener is reachable, for status and logs. */
    public val endpoint: String

    /**
     * Waits for the next connection a host is allowed to make. Throws once [stop] is
     * called, which is how a blocked accept ends; cancelling the caller alone does not.
     */
    public suspend fun accept(): NectoMessageSession

    /** Stops accepting and releases the endpoint. Idempotent. */
    public fun stop()
}
