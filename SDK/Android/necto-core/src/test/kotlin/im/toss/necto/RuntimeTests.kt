// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto

import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoEnvelope
import im.toss.necto.model.NectoHandshakeAck
import im.toss.necto.model.NectoHandshakeHello
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.NectoOperationKind
import im.toss.necto.model.NectoPanelArchive
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.model.NectoPluginCancellation
import im.toss.necto.model.NectoPluginInvocation
import im.toss.necto.model.NectoPluginRegistration
import im.toss.necto.model.NectoPluginResult
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.plugins.NectoEvent
import im.toss.necto.plugins.NectoEventsPlugin
import im.toss.necto.plugins.NectoNetworkPlugin
import im.toss.necto.plugins.NectoNetworkRecord
import im.toss.necto.sdk.NectoAppIdentity
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoRegistrar
import im.toss.necto.sdk.NectoSDK
import im.toss.necto.sdk.NectoSdkRuntime
import im.toss.necto.transport.NectoMessageSession
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class RuntimeTests {
    private val runtime = NectoSdkRuntime()
    private val streamCancelled = AtomicBoolean(false)

    private val testPlugin = object : NectoPlugin {
        override val id = "test"
        override fun register(necto: NectoRegistrar) {
            necto.handle("test.echo") { input -> jsonObject("echo" to input) }
            necto.handle("test.fail") { throw NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "nope") }
            necto.handle("test.crash") { error("boom") }
            necto.handle("test.nan") { jsonOf(Double.NaN) }
            necto.stream("test.ticks") { _, out ->
                repeat(3) { out.send(jsonOf(it)) }
            }
            necto.stream("test.forever") { _, _ ->
                try {
                    awaitCancellation()
                } finally {
                    streamCancelled.set(true)
                }
            }
        }
    }

    init {
        runtime.identity = object : NectoAppIdentity {
            override val appBundleID = "com.example.app"
            override val appName = "Example"
            override val appVersion = "1.0"
            override val deviceName = "Test"
            override val osVersion = "15"
            override val simulatorID = "android:test"
        }
    }

    @AfterTest
    fun tearDown() {
        runtime.shutdown()
    }

    /** Plays the Mac: connects, answers the hello, and collects the registrations. */
    private inner class FakeHost(endpoint: String) {
        val socket = Socket(InetAddress.getLoopbackAddress(), endpoint.toInt())
        val session = LoopbackListener.session(socket)
        val registrations = LinkedHashMap<String, NectoPluginRegistration>()
        lateinit var hello: NectoHandshakeHello

        /** The app's messages may be as large as it likes to send; the host reads them all. */
        suspend fun receive(): NectoJsonValue = session.receiveJson(NectoMessageSession.MAXIMUM_MESSAGE_BYTES)

        suspend fun handshake() {
            hello = NectoHandshakeHello.fromJson(receive())
            session.send(NectoHandshakeAck.evaluate(hello).toJson())
        }

        suspend fun next(): NectoEnvelope {
            while (true) {
                val envelope = NectoEnvelope.fromJson(receive())
                if (envelope.type == NectoEnvelope.Kind.PLUGIN_REGISTER) {
                    val registration = NectoPluginRegistration.fromJson(envelope.payload)
                    registrations[registration.pluginID] = registration
                    continue
                }
                return envelope
            }
        }

        suspend fun result(): NectoPluginResult {
            val envelope = next()
            assertEquals(NectoEnvelope.Kind.PLUGIN_RESULT, envelope.type)
            return NectoPluginResult.fromJson(envelope.payload)
        }

        suspend fun invoke(id: String, name: String, kind: NectoOperationKind = NectoOperationKind.ONCE, input: NectoJsonValue = jsonObject()) {
            val invocation = NectoPluginInvocation(id, "necto.device.$name", 1, kind, input)
            session.send(NectoEnvelope(NectoEnvelope.Kind.PLUGIN_INVOKE, invocation.toJson()).toJson())
        }

        suspend fun cancel(id: String) {
            session.send(NectoEnvelope(NectoEnvelope.Kind.PLUGIN_CANCEL, NectoPluginCancellation(id).toJson()).toJson())
        }

        /** Registrations arrive on their own writer, so wait for them explicitly. */
        suspend fun awaitRegistration(pluginID: String): NectoPluginRegistration {
            while (pluginID !in registrations) {
                val envelope = NectoEnvelope.fromJson(receive())
                assertEquals(NectoEnvelope.Kind.PLUGIN_REGISTER, envelope.type)
                val registration = NectoPluginRegistration.fromJson(envelope.payload)
                registrations[registration.pluginID] = registration
            }
            return registrations.getValue(pluginID)
        }

        /** Writes bytes as they are, framed or not. */
        fun write(bytes: ByteArray) {
            socket.getOutputStream().apply { write(bytes); flush() }
        }

        /** Reads until the app closes the connection, skipping whatever it sent first. */
        suspend fun awaitClosed() {
            while (true) {
                try {
                    session.receive(NectoMessageSession.MAXIMUM_MESSAGE_BYTES)
                } catch (_: IOException) {
                    return
                }
            }
        }
    }

    private fun frame(payload: ByteArray): ByteArray = length(payload.size) + payload

    private fun length(size: Int): ByteArray =
        byteArrayOf((size ushr 24).toByte(), (size ushr 16).toByte(), (size ushr 8).toByte(), size.toByte())

    private var endpoint: String? = null

    /** Starts the runtime once; later calls return the same endpoint. */
    private suspend fun listen(frameTimeoutMillis: Long = NectoMessageSession.FRAME_TIMEOUT_MS): String {
        endpoint?.let { return it }
        runtime.start { LoopbackListener(frameTimeoutMillis) }
        val listening = runtime.status.first { it is NectoSDK.Status.Listening } as NectoSDK.Status.Listening
        return listening.endpoint.also { endpoint = it }
    }

    private suspend fun connect(frameTimeoutMillis: Long = NectoMessageSession.FRAME_TIMEOUT_MS): FakeHost {
        val host = FakeHost(listen(frameTimeoutMillis))
        host.handshake()
        runtime.status.first { it is NectoSDK.Status.Connected }
        return host
    }

    @Test
    fun handshakeCarriesIdentityAndRegistrations() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            val host = connect()
            assertEquals("com.example.app", host.hello.appBundleID)
            assertEquals("android:test", host.hello.simulatorID)
            assertEquals(NectoSDK.VERSION, host.hello.sdkVersion)

            val registration = host.awaitRegistration("test")
            val names = registration.catalog.bridges.map { it.identity }.toSet()
            assertTrue("necto.device.test.echo@1" in names)
            assertEquals(NectoOperationKind.STREAM, registration.catalog.bridges.first { it.name == "necto.device.test.ticks" }.kind)

            // A plugin added mid-session joins it; removal is an empty catalog.
            runtime.register(NectoEventsPlugin())
            val events = host.awaitRegistration("event-log")
            assertNotNull(events.panel?.contentHash)
            host.registrations.remove("event-log")
            runtime.unregister("event-log")
            assertTrue(host.awaitRegistration("event-log").catalog.bridges.isEmpty())
        }
    }

    @Test
    fun onceCallsAnswerWithOutputOrError() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            val host = connect()

            host.invoke("1", "test.echo", input = jsonObject("x" to jsonOf(1)))
            assertEquals(jsonObject("echo" to jsonObject("x" to jsonOf(1))), host.result().output)

            host.invoke("2", "test.fail")
            assertEquals(NectoBridgeErrorCode.INVALID_INPUT, host.result().error?.code)

            host.invoke("3", "test.crash")
            val crash = host.result()
            assertEquals(NectoBridgeErrorCode.PROVIDER_FAILED, crash.error?.code)
            assertEquals("boom", crash.error?.message)

            host.invoke("4", "test.nan")
            assertEquals("The result could not be encoded as JSON", host.result().error?.message)

            host.invoke("5", "test.missing")
            assertEquals(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, host.result().error?.code)
        }
    }

    @Test
    fun streamsSendEventsThenAFinalResultAndStopOnCancel() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            val host = connect()

            host.invoke("s", "test.ticks", NectoOperationKind.STREAM)
            val results = List(4) { host.result() }
            assertEquals(listOf(jsonOf(0), jsonOf(1), jsonOf(2), null), results.map { it.output })
            assertEquals(listOf(false, false, false, true), results.map { it.isFinal })

            host.invoke("f", "test.forever", NectoOperationKind.STREAM)
            delay(200)
            host.cancel("f")
            withTimeout(2_000) { while (!streamCancelled.get()) delay(20) }
        }
    }

    @Test
    fun panelsAreServedByTheSdk() = runBlocking<Unit> {
        withTimeout(10_000) {
            val events = NectoEventsPlugin()
            runtime.register(events)
            val host = connect()
            val stamp = host.awaitRegistration("event-log").panel!!

            host.invoke("p", "plugins.assets", input = jsonObject("pluginID" to jsonOf("event-log")))
            val archive = NectoPanelArchive.fromJson(host.result().output!!)
            assertEquals(stamp.contentHash, archive.contentHash)
            assertTrue(archive.files.any { it.path == "manifest.json" })
            assertFalse(archive.files.any { it.path == "files.txt" })

            host.invoke("q", "plugins.assets", input = jsonObject("pluginID" to jsonOf("test")))
            assertEquals(NectoBridgeErrorCode.OPERATION_UNAVAILABLE, host.result().error?.code)
        }
    }

    @Test
    fun panelsAreReadOnceWhenAHostFirstNeedsThem() = runBlocking<Unit> {
        withTimeout(10_000) {
            val real = NectoEventsPlugin().panel!!
            val reads = java.util.concurrent.atomic.AtomicInteger()
            val registeringThread = Thread.currentThread()
            var readingThread: Thread? = null
            val plugin = object : NectoPlugin {
                override val id = "lazy-panel"
                override val panel = NectoPluginPanel {
                    reads.incrementAndGet()
                    readingThread = Thread.currentThread()
                    real.read()
                }
                override fun register(necto: NectoRegistrar) = Unit
            }

            runtime.register(plugin)
            assertEquals(0, reads.get(), "registering does not read the panel")

            val host = connect()
            assertNotNull(host.awaitRegistration("lazy-panel").panel)
            assertEquals(1, reads.get())
            assertTrue(readingThread !== registeringThread, "the panel is read off the registering thread")

            host.invoke("p", "plugins.assets", input = jsonObject("pluginID" to jsonOf("lazy-panel")))
            assertNotNull(host.result().output)
            assertEquals(1, reads.get(), "the panel is read once and then held")
        }
    }

    @Test
    fun eventsAndNetworkPluginsReportToObservers() = runBlocking<Unit> {
        withTimeout(10_000) {
            val events = NectoEventsPlugin()
            val network = NectoNetworkPlugin()
            runtime.register(events)
            runtime.register(network)
            val host = connect()

            host.invoke("o", "events.observe", NectoOperationKind.STREAM)
            delay(200)
            events.report(NectoEvent(NectoEvent.Level.WARN, "Cache", "Evicted", mapOf("count" to "240")))
            val observed = host.result()
            assertFalse(observed.isFinal)
            assertEquals(jsonOf("Evicted"), observed.output?.get("event")?.get("message"))
            val eventID = observed.output!!["event"]!!["id"]!!.stringValue!!

            host.invoke("d", "events.detail", input = jsonObject("eventID" to jsonOf(eventID)))
            assertEquals(jsonOf("240"), host.result().output?.get("event")?.get("detail")?.get("count"))

            network.report(NectoNetworkRecord("r", "GET", "https://example.com/v1/items?page=2", 1.0, NectoNetworkRecord.State.PENDING))
            network.report(
                NectoNetworkRecord(
                    "r", "GET", "https://example.com/v1/items?page=2", 1.0, NectoNetworkRecord.State.COMPLETED,
                    statusCode = 200, responseBody = NectoNetworkRecord.Body.of("{}".toByteArray(), "application/json"),
                ),
            )
            host.invoke("l", "network-records.list")
            val records = host.result().output!!["records"]!!.arrayValue!!
            assertEquals(1, records.size)
            assertEquals(jsonOf("items?page=2"), records[0]["name"])
            assertEquals(jsonOf(200), records[0]["statusCode"])

            host.invoke("rd", "network-records.detail", input = jsonObject("recordID" to jsonOf("r")))
            assertEquals(jsonOf("{}"), host.result().output!!["record"]!!["responseBody"]!!["text"])
        }
    }

    @Test
    fun hostDisconnectReturnsToListening() = runBlocking<Unit> {
        withTimeout(10_000) {
            val host = connect()
            host.session.close()
            runtime.status.first { it is NectoSDK.Status.Listening }
            // The listener takes the next host.
            val listening = runtime.status.value as NectoSDK.Status.Listening
            val second = FakeHost(listening.endpoint)
            second.handshake()
            runtime.status.first { it is NectoSDK.Status.Connected }
        }
    }

    @Test
    fun aNewerHostReplacesOneThatWentQuiet() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            // A host whose cable was pulled: the connection stays open and says nothing.
            val quiet = connect()
            val next = FakeHost(listen())
            next.handshake()
            quiet.awaitClosed()
            next.invoke("replaced", "test.echo")
            assertEquals("replaced", next.result().requestID)
            assertTrue(runtime.status.value is NectoSDK.Status.Connected)
        }
    }

    @Test
    fun aHostStillSayingHelloLeavesTheConnectedOneAlone() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            val host = connect()
            val pending = FakeHost(listen())
            pending.receive()
            host.invoke("kept", "test.echo")
            assertEquals("kept", host.result().requestID)
            // A refused handshake does not replace it either, nor change what it reports.
            pending.session.send(NectoHandshakeAck(accepted = false, rejection = NectoHandshakeAck.Rejection.MISSING_APP_IDENTITY).toJson())
            pending.awaitClosed()
            host.invoke("still", "test.echo")
            assertEquals("still", host.result().requestID)
            assertTrue(runtime.status.value is NectoSDK.Status.Connected)
        }
    }

    // MARK: A host that misbehaves

    /**
     * Asserts the app dropped [host] and still takes the next one, then lets that one go:
     * the app serves one host at a time, so the next test case would otherwise wait.
     */
    private suspend fun assertDroppedAndRecovers(host: FakeHost) {
        host.awaitClosed()
        val next = FakeHost(listen())
        next.handshake()
        next.invoke("recovered", "test.echo")
        assertEquals("recovered", next.result().requestID)
        next.session.close()
        runtime.status.first { it is NectoSDK.Status.Listening }
    }

    @Test
    fun framesOutsideTheInboundLimitCloseTheSession() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            for (size in listOf(0, NectoMessageSession.MAXIMUM_INBOUND_BYTES + 1, -1)) {
                val host = connect()
                host.write(length(size))
                assertDroppedAndRecovers(host)
            }
        }
    }

    @Test
    fun malformedMessagesCloseTheSession() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            val nested = "{\"input\":" + "[".repeat(65) + "0" + "]".repeat(65) + "}"
            val invalidUtf8 = byteArrayOf('"'.code.toByte(), 0xC3.toByte(), 0x28, '"'.code.toByte())
            for (payload in listOf(nested.toByteArray(), invalidUtf8, "{} {}".toByteArray())) {
                val host = connect()
                host.write(frame(payload))
                assertDroppedAndRecovers(host)
            }
        }
    }

    @Test
    fun aStalledFrameClosesTheSession() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            val host = connect(frameTimeoutMillis = 300)
            host.write(byteArrayOf(0))
            assertDroppedAndRecovers(host)
        }
    }

    @Test
    fun aHostThatNeverAnswersTheHelloIsDropped() = runBlocking<Unit> {
        withTimeout(10_000) {
            val host = FakeHost(listen())
            host.receive()
            val started = System.nanoTime()
            host.awaitClosed()
            val elapsed = (System.nanoTime() - started) / 1_000_000
            assertTrue(elapsed in 3_000..8_000, "closed after $elapsed ms")
        }
    }

    @Test
    fun anAckLargerThanAnAckClosesTheSession() = runBlocking<Unit> {
        withTimeout(10_000) {
            val host = FakeHost(listen())
            host.receive()
            host.write(frame(ByteArray(4097) { ' '.code.toByte() }))
            host.awaitClosed()
        }
    }

    @Test
    fun requestIDsMustBeShortAndUnique() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            for (id in listOf("", "x".repeat(129))) {
                val host = connect()
                host.invoke(id, "test.echo")
                assertDroppedAndRecovers(host)
            }

            val host = connect()
            host.invoke("x".repeat(128), "test.echo")
            assertEquals("x".repeat(128), host.result().requestID)
            host.invoke("same", "test.forever", NectoOperationKind.STREAM)
            host.invoke("same", "test.forever", NectoOperationKind.STREAM)
            assertDroppedAndRecovers(host)
        }
    }

    @Test
    fun tooManyActiveRequestsCloseTheSession() = runBlocking<Unit> {
        withTimeout(10_000) {
            runtime.register(testPlugin)
            val host = connect()
            repeat(32) { host.invoke("$it", "test.forever", NectoOperationKind.STREAM) }
            // Thirty two may run at once; the next is one too many while they still are.
            host.invoke("33", "test.echo")
            assertDroppedAndRecovers(host)
        }
    }
}
