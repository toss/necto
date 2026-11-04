// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.testing

import im.toss.necto.model.NectoJsonValue
import im.toss.necto.model.jsonObject
import im.toss.necto.sdk.NectoOut
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoRegistrar

/** Invokes registered handlers without making the runtime's registry a public SDK API. */
public class PluginHarness(plugin: NectoPlugin) {
    private val registrar = NectoRegistrar().also(plugin::register)

    public suspend fun call(name: String, input: NectoJsonValue = jsonObject()): NectoJsonValue {
        val body = registrar.registrations.getValue("necto.device.$name@1").body as NectoRegistrar.Body.Once
        return body.run(input)
    }

    public suspend fun observe(name: String, input: NectoJsonValue, out: NectoOut) {
        val body = registrar.registrations.getValue("necto.device.$name@1").body as NectoRegistrar.Body.Stream
        body.run(input, out)
    }
}
