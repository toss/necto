// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import android.content.Context
import android.os.Build
import android.provider.Settings
import im.toss.necto.model.jsonObject
import im.toss.necto.model.jsonOf
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.sdk.NectoPluginPanel
import im.toss.necto.sdk.NectoRegistrar
import kotlinx.coroutines.delay

/**
 * Answers questions about this app, so the app bridge round trip has something real
 * to exercise.
 *
 * The interesting half of the bridge: everything else in this app pushes, while this
 * waits to be asked. A plugin on the Mac calls its own operation id, the runtime
 * resolves that to `com.example.app.state@1`, and the request travels here.
 */
class ExampleContractPlugin(context: Context) : NectoPlugin {
    private val context = context.applicationContext

    override val id: String = "plugin-sample"

    // Carried in the APK as Java resources rather than in a library: a panels/<id> folder
    // and its files.txt index are the whole arrangement, which is the other way an app
    // can bring a panel along. The build copies the repository's built plugin-sample
    // panel there, the same one ExampleApp carries.
    override val panel: NectoPluginPanel =
        NectoPluginPanel.resources("panels/plugin-sample", ExampleContractPlugin::class.java.classLoader!!)

    override fun register(necto: NectoRegistrar) {
        necto.handle("com.example.app.state") { input ->
            // The note is echoed back so a caller can prove the input reached the
            // device rather than being answered somewhere on the way.
            jsonObject(
                "appVersion" to jsonOf(appVersion()),
                "deviceName" to jsonOf(deviceName()),
                "note" to jsonOf(input["note"]?.stringValue ?: ""),
            )
        }

        necto.stream("com.example.app.counter") { input, out ->
            val count = maxOf(1, (input["count"]?.numberValue ?: 3.0).toInt())
            for (step in 1..count) {
                out.send(jsonObject("step" to jsonOf(step)))
                delay(200)
            }
        }
    }

    private fun appVersion(): String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "0"

    /** The name the owner gave the device, as UIDevice.name is on iOS; the model otherwise. */
    private fun deviceName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: Build.MODEL
}
