// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto

import im.toss.necto.model.NectoBridgeCatalog
import im.toss.necto.model.NectoBridgeError
import im.toss.necto.model.NectoBridgeErrorCode
import im.toss.necto.model.NectoHandshakeAck
import im.toss.necto.model.NectoHandshakeHello
import im.toss.necto.model.NectoJsonSchema
import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.NectoPanelArchive
import im.toss.necto.model.NectoPluginInvocation
import im.toss.necto.model.NectoPluginManifest
import im.toss.necto.model.NectoPluginResult
import im.toss.necto.model.NectoSemanticVersion
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ModelTests {
    @Test
    fun jsonRoundTripsAndWritesIntegersWithoutFraction() {
        val text = """{"a":1,"b":1.5,"c":[true,false,null],"d":"q\"\\\n\u0001é","e":{},"f":-2e3}"""
        val value = NectoJsonValue.parse(text)
        assertEquals(jsonOf(1), value["a"])
        assertEquals(jsonOf(-2000), value["f"])
        assertEquals("""{"a":1,"b":1.5,"c":[true,false,null],"d":"q\"\\\n\u0001é","e":{},"f":-2000}""", value.toJson())
        assertEquals(value, NectoJsonValue.parse(value.toJson()))
    }

    @Test
    fun jsonRejectsNonFiniteNumbersAndMalformedText() {
        assertFailsWith<Exception> { jsonOf(Double.NaN).toJson() }
        assertFailsWith<Exception> { NectoJsonValue.parse("{\"a\":}") }
        assertFailsWith<Exception> { NectoJsonValue.parse("[1,]") }
        assertFailsWith<Exception> { NectoJsonValue.parse("1 2") }
    }

    @Test
    fun fromConvertsKotlinGraphs() {
        val value = NectoJsonValue.from(mapOf("list" to listOf(1, "x", null), "flag" to true))
        assertEquals("""{"list":[1,"x",null],"flag":true}""", value!!.toJson())
        assertNull(NectoJsonValue.from(mapOf(1 to 2)))
        assertNull(NectoJsonValue.from(Any()))
    }

    @Test
    fun schemaValidatesLikeTheSwiftImplementation() {
        val schema = NectoJsonValue.parse(
            """{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":10},
               "level":{"type":"string","enum":["debug","info"]},"tags":{"type":"array","items":{"type":"string"},"maxItems":2}},
               "required":["limit"],"additionalProperties":false}""",
        )
        assertNull(NectoJsonSchema.validate(NectoJsonValue.parse("""{"limit":3,"level":"info","tags":["a"]}"""), schema))
        assertEquals("limit: is required", NectoJsonSchema.validate(jsonObject(), schema).toString())
        assertEquals("limit: must be of type integer", NectoJsonSchema.validate(NectoJsonValue.parse("""{"limit":1.5}"""), schema).toString())
        assertEquals("limit: must be less than or equal to 10.0", NectoJsonSchema.validate(NectoJsonValue.parse("""{"limit":11}"""), schema).toString())
        assertEquals("level: is not one of the allowed values", NectoJsonSchema.validate(NectoJsonValue.parse("""{"limit":1,"level":"x"}"""), schema).toString())
        assertEquals("tags[1]: must be of type string", NectoJsonSchema.validate(NectoJsonValue.parse("""{"limit":1,"tags":["a",2]}"""), schema).toString())
        assertEquals("extra: is not declared in the schema", NectoJsonSchema.validate(NectoJsonValue.parse("""{"limit":1,"extra":0}"""), schema).toString())
    }

    @Test
    fun semanticVersionsParseStrictly() {
        assertEquals(NectoSemanticVersion(1, 2, 3, "beta.1", "7"), NectoSemanticVersion.parse("1.2.3-beta.1+7"))
        assertNull(NectoSemanticVersion.parse("1.2"))
        assertNull(NectoSemanticVersion.parse("01.2.3"))
        assertNull(NectoSemanticVersion.parse("1.2.3-"))
        assertTrue(NectoSemanticVersion.parse("1.10.0")!! > NectoSemanticVersion.parse("1.9.9")!!)
    }

    @Test
    fun panelHashesMatchTheSwiftAlgorithm() {
        // Expected values computed independently from the Swift definition:
        // UInt64 big-endian lengths around each path and body, files sorted by path.
        val archive = NectoPanelArchive(
            listOf(
                NectoPanelArchive.File("manifest.json", "{}".toByteArray()),
                NectoPanelArchive.File("index.html", "<html></html>".toByteArray()),
                NectoPanelArchive.File("assets/index.js", "console.log(1)".toByteArray()),
            ),
        )
        assertEquals("0fb5527783fe50d26d90d1a06e83617dded86940555b3f1af1b2ad1d89e6eeab", archive.contentHash)
        assertEquals("a9a434f98a284d3fe2e68ffed794ef2ebc2718fd19e760031c86d9bb3bae4793", archive.legacyContentHash)
        assertEquals(archive, NectoPanelArchive.fromJson(archive.toJson()))
    }

    @Test
    fun handshakeAndMessagesUseTheSwiftKeys() {
        val hello = NectoHandshakeHello(
            appBundleID = "com.example",
            appName = "Example",
            deviceName = "Pixel",
            sdkVersion = "0.1.0",
            appIcon = byteArrayOf(1, 2, 3),
            simulatorID = "android:abc",
        )
        assertEquals(
            """{"protocolVersion":1,"appBundleID":"com.example","appName":"Example","appVersion":"","deviceName":"Pixel",""" +
                """"osVersion":"","sdkVersion":"0.1.0","appIcon":"AQID","simulatorID":"android:abc"}""",
            hello.toJson().toJson(),
        )
        assertEquals(hello, NectoHandshakeHello.fromJson(hello.toJson()))
        assertTrue(NectoHandshakeAck.evaluate(hello).accepted)
        assertEquals(
            NectoHandshakeAck.Rejection.MISSING_APP_IDENTITY,
            NectoHandshakeAck.evaluate(hello.copy(appBundleID = "")).rejection,
        )
        val ack = NectoHandshakeAck.fromJson(NectoJsonValue.parse("""{"accepted":true,"hostProtocolVersion":1}"""))
        assertTrue(ack.accepted)

        val invocation = NectoPluginInvocation.fromJson(
            NectoJsonValue.parse("""{"requestID":"r1","name":"necto.device.x","version":1,"kind":"stream","input":{}}"""),
        )
        assertEquals("r1", invocation.requestID)

        val failure = NectoPluginResult("r1", error = NectoBridgeError(NectoBridgeErrorCode.INVALID_INPUT, "bad"))
        assertEquals("""{"requestID":"r1","error":{"code":"INVALID_INPUT","message":"bad"},"isFinal":true}""", failure.toJson().toJson())
        assertEquals(failure, NectoPluginResult.fromJson(failure.toJson()))
        assertEquals(1, NectoBridgeCatalog(emptyList()).catalogVersion)
    }

    @Test
    fun shippedPanelManifestsValidate() {
        // Generated from the iOS SDK's built panels before the tests compile.
        val panels = File("build/generated/panelResources/necto/panels").listFiles()!!.filter { it.isDirectory }
        assertTrue(panels.size >= 6)
        for (panel in panels) {
            val manifest = NectoPluginManifest.fromJson(NectoJsonValue.parse(panel.resolve("manifest.json").readText()))
            manifest.validate()
            assertEquals(panel.name, manifest.id)
            assertTrue(manifest.requiresTarget)
            assertNotNull(NectoPanelArchive.read(panel).files.firstOrNull { it.path == "index.html" })
        }
    }
}
