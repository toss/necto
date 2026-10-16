// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sdk

import im.toss.necto.model.NectoBridgeCatalog
import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoEnvelope
import im.toss.necto.model.NectoHandshakeAck
import im.toss.necto.model.NectoHandshakeHello
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.NectoPanelArchive
import im.toss.necto.model.NectoPluginCancellation
import im.toss.necto.model.NectoPluginInvocation
import im.toss.necto.model.NectoPluginRegistration
import im.toss.necto.model.NectoPluginResult
import im.toss.necto.transport.NectoListener
import im.toss.necto.transport.NectoMessageSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Holds the listener, the session and the registered plugins behind [NectoSDK].
 *
 * Everything here is about moving messages. Plugins are looked up by contract name and
 * handed the payload untouched, so adding a capability to an app never changes this file.
 */
internal class NectoSdkRuntime(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val lock = Any()
    private var listener: NectoListener? = null
    private var serveJob: Job? = null
    private var generation: Any? = null

    /** Held for the life of the connection. */
    private var session: NectoMessageSession? = null
    private val statusFlow = MutableStateFlow<NectoSDK.Status>(NectoSDK.Status.Stopped)
    private val registered = ArrayList<NectoPlugin>()
    private val registeringIDs = HashSet<String>()
    private val requests = HashMap<String, Pair<Any, Job>>()
    /** IDs of plugins whose registration changed while connected. */
    private var registrationUpdates: Channel<String>? = null
    private var registrationWriter: Job? = null

    /** What each plugin answers, read from `register` when it was added. */
    private val handlers = HashMap<String, Map<String, NectoRegistrar.Registration>>()

    /**
     * Where each plugin's panel comes from. A panel is read the first time a host needs
     * it, off the thread that registered the plugin (usually the main thread during app
     * start), then held whole.
     */
    private val panelSources = HashMap<String, NectoPluginPanel>()
    private val panels = HashMap<String, NectoPanelArchive>()
    private val unreadablePanels = HashSet<String>()

    @Volatile
    var identity: NectoAppIdentity = NectoJvmAppIdentity

    val status: StateFlow<NectoSDK.Status> = statusFlow.asStateFlow()

    val plugins: List<NectoPlugin> get() = synchronized(lock) { registered.toList() }

    private fun setStatusLocked(value: NectoSDK.Status) {
        statusFlow.value = value
    }

    private fun setStatus(value: NectoSDK.Status, session: NectoMessageSession) {
        synchronized(lock) { if (this.session === session) setStatusLocked(value) }
    }

    // MARK: Plugins

    fun register(plugin: NectoPlugin): Boolean {
        val id = plugin.id
        val reserved = synchronized(lock) {
            registered.none { it.id == id } && registeringIDs.add(id)
        }
        if (!reserved) return false
        try {
            val collector = NectoRegistrar()
            plugin.register(collector)
            if (collector.hasDuplicateContracts) return false
            val registrations = collector.registrations.toMap()

            return synchronized(lock) {
                val existing = handlers.values.flatMap { it.keys }.toSet()
                if (registrations.keys.any { it in existing }) return@synchronized false
                registered.add(plugin)
                handlers[id] = registrations
                plugin.panel?.let { panelSources[id] = it }
                enqueueRegistrationLocked(id)
                true
            }
        } finally {
            synchronized(lock) { registeringIDs.remove(id) }
        }
    }

    /** Takes a plugin away, from the app and from the host (an empty catalog says so). */
    fun unregister(id: String) {
        synchronized(lock) {
            val index = registered.indexOfFirst { it.id == id }
            if (index < 0) return
            handlers.remove(id)
            panelSources.remove(id)
            panels.remove(id)
            unreadablePanels.remove(id)
            registered.removeAt(index)
            enqueueRegistrationLocked(id)
        }
    }

    private fun registration(invocation: NectoPluginInvocation): NectoRegistrar.Registration? {
        val identity = "${invocation.name}@${invocation.version}"
        return synchronized(lock) { handlers.values.firstNotNullOfOrNull { it[identity] } }
    }

    // MARK: Listening

    fun start(listen: () -> NectoListener) {
        synchronized(lock) {
            if (serveJob != null) return
            val generation = Any()
            this.generation = generation
            serveJob = scope.launch {
                while (isActive) {
                    serve(listen, generation)
                    if (!isActive) return@launch
                    delay(RETRY_DELAY_MS)
                }
            }
        }
    }

    /** Accepts connections until the listener goes away. One session at a time. */
    private suspend fun serve(listen: () -> NectoListener, generation: Any) {
        val listener = try {
            listen()
        } catch (error: Exception) {
            synchronized(lock) {
                if (this.generation === generation) setStatusLocked(NectoSDK.Status.Failed(error.message ?: error.toString()))
            }
            return
        }
        val active = synchronized(lock) {
            if (this.generation !== generation) return@synchronized false
            this.listener = listener
            setStatusLocked(NectoSDK.Status.Listening(listener.endpoint))
            true
        }
        if (!active) {
            listener.stop()
            return
        }

        try {
            while (currentCoroutineContext().isActive) {
                val session = listener.accept()
                if (!currentCoroutineContext().isActive) {
                    session.close()
                    break
                }
                handle(session)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            synchronized(lock) {
                if (this.generation === generation) setStatusLocked(NectoSDK.Status.Failed(error.message ?: error.toString()))
            }
        } finally {
            listener.stop()
            synchronized(lock) { if (this.listener === listener) this.listener = null }
        }
    }

    fun stop() {
        val closing = synchronized(lock) {
            val closing = Triple(serveJob, listener, session)
            serveJob = null
            generation = null
            listener = null
            session = null
            stopRegistrationUpdatesLocked()
            val pending = requests.values.map { it.second }
            requests.clear()
            setStatusLocked(NectoSDK.Status.Stopped)
            closing to pending
        }
        val (jobs, pending) = closing
        jobs.first?.cancel()
        pending.forEach { it.cancel() }
        // Closing is what wakes a blocked accept or read.
        jobs.third?.close()
        jobs.second?.stop()
    }

    /** Ends every coroutine this runtime started. For tests; the SDK object lives forever. */
    fun shutdown() {
        stop()
        scope.cancel()
    }

    // MARK: Session

    /** Drives one session to completion, independently of how it was obtained. */
    suspend fun accept(session: NectoMessageSession) {
        handle(session)
    }

    /** Says hello, tells the host what this app offers, then reads until it goes away. */
    private suspend fun handle(session: NectoMessageSession) {
        val active = currentCoroutineContextIsActive()
        val previous = synchronized(lock) {
            if (!active) return@synchronized null
            val previous = this.session to requests.values.map { it.second }
            requests.clear()
            stopRegistrationUpdatesLocked()
            this.session = session
            previous
        }
        if (previous == null) {
            session.close()
            return
        }
        previous.first?.close()
        previous.second.forEach { it.cancel() }

        try {
            val identity = identity
            val hello = NectoHandshakeHello(
                appBundleID = identity.appBundleID,
                appName = identity.appName,
                appVersion = identity.appVersion,
                deviceName = identity.deviceName,
                osVersion = identity.osVersion,
                sdkVersion = NectoSDK.VERSION,
                appIcon = identity.appIcon,
                simulatorID = identity.simulatorID,
            )
            val ack = handshake(session) {
                session.send(hello.toJson())
                NectoHandshakeAck.fromJson(session.receiveJson(MAXIMUM_ACK_BYTES))
            }
            if (!ack.accepted) {
                setStatus(NectoSDK.Status.Failed("Necto refused the connection: ${ack.rejection?.rawValue ?: "unknown"}"), session)
                session.close()
                return
            }
            if (synchronized(lock) { this.session !== session } || !currentCoroutineContextIsActive()) {
                session.close()
                return
            }
            setStatus(NectoSDK.Status.Connected(hello.appBundleID), session)

            startRegistrationUpdates(session)
            readMessages(session)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            setStatus(NectoSDK.Status.Failed(error.message ?: error.toString()), session)
            session.close()
        } finally {
            disconnect(session)
        }
    }

    /** Past the deadline the session is closed, which fails the pending read or write. */
    private suspend fun <T> handshake(session: NectoMessageSession, block: suspend () -> T): T {
        val watchdog = scope.launch {
            delay(HANDSHAKE_TIMEOUT_MS)
            session.close()
        }
        try {
            return block()
        } finally {
            watchdog.cancel()
        }
    }

    private suspend fun readMessages(session: NectoMessageSession) {
        while (currentCoroutineContext().isActive) {
            val envelope = try {
                NectoEnvelope.fromJson(session.receiveJson())
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                break
            }
            // A host that breaks the protocol is not answered further.
            if (!route(envelope, session)) break
        }
    }

    /** Returns false when [envelope] breaks the protocol, which ends the session. */
    private fun route(envelope: NectoEnvelope, session: NectoMessageSession): Boolean {
        when (envelope.type) {
            NectoEnvelope.Kind.PLUGIN_INVOKE -> {
                val invocation = runCatching { NectoPluginInvocation.fromJson(envelope.payload) }.getOrNull() ?: return false
                if (invocation.requestID.length !in 1..MAXIMUM_REQUEST_ID_LENGTH) return false
                synchronized(lock) {
                    if (this.session !== session) return true
                    // The host never reuses an ID it is still waiting on, nor floods the app.
                    if (requests.containsKey(invocation.requestID)) return false
                    if (requests.size >= MAXIMUM_ACTIVE_REQUESTS) return false
                    val token = Any()
                    val job = scope.launch(start = CoroutineStart.LAZY) {
                        try {
                            perform(invocation, session)
                        } finally {
                            synchronized(lock) {
                                if (requests[invocation.requestID]?.first === token) requests.remove(invocation.requestID)
                            }
                        }
                    }
                    requests[invocation.requestID] = token to job
                    job.start()
                }
            }
            NectoEnvelope.Kind.PLUGIN_CANCEL -> {
                val cancel = runCatching { NectoPluginCancellation.fromJson(envelope.payload) }.getOrNull() ?: return false
                val job = synchronized(lock) {
                    if (this.session !== session) null else requests.remove(cancel.requestID)?.second
                }
                job?.cancel()
            }
            // The host never sends these, so an app receiving one is a host bug.
            NectoEnvelope.Kind.PLUGIN_REGISTER,
            NectoEnvelope.Kind.PLUGIN_EVENT,
            NectoEnvelope.Kind.PLUGIN_RESULT,
            -> Unit
        }
        return true
    }

    // MARK: App contracts

    private fun bridgeError(error: Throwable): NectoBridgeError =
        error as? NectoBridgeError ?: NectoBridgeError(NectoBridgeErrorCode.PROVIDER_FAILED, error.message ?: error.toString())

    private suspend fun perform(invocation: NectoPluginInvocation, session: NectoMessageSession) {
        // The panel fetch is answered by the SDK itself: the panel belongs to the
        // registration, not to any operation the plugin declared.
        if (invocation.name == PANEL_FETCH_NAME && invocation.version == PANEL_FETCH_VERSION) {
            val pluginID = invocation.input["pluginID"]?.stringValue ?: ""
            val archive = panel(pluginID)
            val result = if (archive != null) {
                NectoPluginResult(invocation.requestID, output = archive.toJson())
            } else {
                NectoPluginResult(
                    invocation.requestID,
                    error = NectoBridgeError(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, "'$pluginID' carries no panel"),
                )
            }
            send(result, session)
            return
        }

        val registration = registration(invocation) ?: run {
            send(
                NectoPluginResult(
                    invocation.requestID,
                    error = NectoBridgeError(
                        NectoBridgeErrorCode.OPERATION_UNAVAILABLE,
                        "No plugin registered '${invocation.name}@${invocation.version}'",
                    ),
                ),
                session,
            )
            return
        }

        when (val body = registration.body) {
            is NectoRegistrar.Body.Once -> {
                val result = try {
                    NectoPluginResult(invocation.requestID, output = body.run(invocation.input))
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    NectoPluginResult(invocation.requestID, error = bridgeError(error))
                }
                send(result, session)
            }
            is NectoRegistrar.Body.Stream -> {
                val out = NectoOut { value ->
                    send(NectoPluginResult(invocation.requestID, output = value, isFinal = false), session)
                }
                try {
                    body.run(invocation.input, out)
                    send(NectoPluginResult(invocation.requestID), session)
                } catch (error: CancellationException) {
                    // The caller stopped listening. Nothing to report.
                    throw error
                } catch (error: Throwable) {
                    send(NectoPluginResult(invocation.requestID, error = bridgeError(error)), session)
                }
            }
        }
    }

    private fun startRegistrationUpdates(session: NectoMessageSession) {
        synchronized(lock) {
            if (this.session !== session) return
            val initial = registered.map { it.id }
            val updates = Channel<String>(REGISTRATION_BUFFER)
            registrationUpdates = updates
            registrationWriter = scope.launch {
                try {
                    for (id in initial) {
                        val registration = registration(id)
                        if (registration.catalog.bridges.isNotEmpty() || registration.panel != null) {
                            sendRegistration(registration, session)
                        }
                    }
                    // An update is sent even when empty: that is how a removal reaches the host.
                    for (id in updates) sendRegistration(registration(id), session)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    disconnect(session)
                }
            }
        }
    }

    /** What the host is told about plugin [id] now. Reads its panel if not read yet. */
    private fun registration(id: String): NectoPluginRegistration {
        val bridges = synchronized(lock) { handlers[id].orEmpty().values.map { it.descriptor } }
        return NectoPluginRegistration(
            pluginID = id,
            catalog = NectoBridgeCatalog(bridges = bridges),
            panel = panel(id)?.stamp,
        )
    }

    /** The panel of plugin [id], read once on first use. Null when it has none or it failed. */
    private fun panel(id: String): NectoPanelArchive? {
        val source = synchronized(lock) {
            panels[id]?.let { return it }
            if (id in unreadablePanels) return null
            panelSources[id] ?: return null
        }
        // A panel that fails to read is a build problem: say so where the developer is.
        val archive = runCatching { source.read() }
            .onFailure { System.err.println("Necto: the panel of '$id' could not be read: $it") }
            .getOrNull()
        return synchronized(lock) {
            // The plugin may have been taken away, or registered again, while reading.
            if (panelSources[id] !== source) return@synchronized panels[id]
            if (archive != null) panels[id] = archive else unreadablePanels += id
            archive
        }
    }

    private fun enqueueRegistrationLocked(id: String) {
        val updates = registrationUpdates ?: return
        if (updates.trySend(id).isFailure) {
            // Losing a catalog update would leave stale permissions. Reconnect for a full snapshot.
            stopRegistrationUpdatesLocked()
            session?.close()
        }
    }

    private fun stopRegistrationUpdatesLocked() {
        registrationUpdates?.close()
        registrationUpdates = null
        registrationWriter?.cancel()
        registrationWriter = null
    }

    private suspend fun sendRegistration(registration: NectoPluginRegistration, session: NectoMessageSession) {
        sendEnvelope(NectoEnvelope(NectoEnvelope.Kind.PLUGIN_REGISTER, registration.toJson()), session)
    }

    // MARK: Sending

    private suspend fun send(result: NectoPluginResult, session: NectoMessageSession) {
        currentCoroutineContext().ensureActive()
        if (synchronized(lock) { this.session !== session }) return
        val envelope = NectoEnvelope(NectoEnvelope.Kind.PLUGIN_RESULT, result.toJson())
        val encodes = runCatching { envelope.toJson().toJson() }.isSuccess
        // An output that will not encode (NaN, most likely) would leave the host waiting
        // out its timeout, so the failure is sent in its place.
        val sendable = if (encodes) {
            envelope
        } else {
            NectoEnvelope(
                NectoEnvelope.Kind.PLUGIN_RESULT,
                NectoPluginResult(
                    result.requestID,
                    error = NectoBridgeError(NectoBridgeErrorCode.PROVIDER_FAILED, "The result could not be encoded as JSON"),
                ).toJson(),
            )
        }
        runCatching { sendEnvelope(sendable, session) }
            .onFailure { if (it is CancellationException) throw it }
    }

    /** A send failure means the host went away, so the session is dropped. */
    private suspend fun sendEnvelope(envelope: NectoEnvelope, session: NectoMessageSession) {
        if (synchronized(lock) { this.session !== session }) return
        try {
            session.send(envelope.toJson())
        } catch (error: Exception) {
            if (error !is CancellationException) disconnect(session)
            throw error
        }
    }

    private fun disconnect(session: NectoMessageSession) {
        val pending = synchronized(lock) {
            if (this.session !== session) return@synchronized null
            this.session = null
            stopRegistrationUpdatesLocked()
            setStatusLocked(listener?.let { NectoSDK.Status.Listening(it.endpoint) } ?: NectoSDK.Status.Stopped)
            requests.values.map { it.second }.also { requests.clear() }
        }
        session.close()
        pending?.forEach { it.cancel() }
    }

    private suspend fun currentCoroutineContextIsActive(): Boolean = currentCoroutineContext().isActive

    companion object {
        /** Long enough not to spin while the app is in the background. */
        private const val RETRY_DELAY_MS = 1_000L
        private const val HANDSHAKE_TIMEOUT_MS = 5_000L

        /** The host's acknowledgement is a few fields; anything larger is not one. */
        private const val MAXIMUM_ACK_BYTES = 4096
        private const val MAXIMUM_ACTIVE_REQUESTS = 32
        private const val MAXIMUM_REQUEST_ID_LENGTH = 128
        private const val REGISTRATION_BUFFER = 64

        /** The device side of the panel fetch, answered by the SDK itself. */
        const val PANEL_FETCH_NAME: String = "necto.device.plugins.assets"
        const val PANEL_FETCH_VERSION: Int = 1
    }
}
