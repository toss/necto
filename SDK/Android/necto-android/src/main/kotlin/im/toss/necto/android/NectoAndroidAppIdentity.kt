// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.provider.Settings
import im.toss.necto.sdk.NectoAppIdentity
import java.io.ByteArrayOutputStream

/**
 * The handshake identity of an Android app, read from its `Context`, so an app never
 * has to hand Necto what it already declares in its manifest.
 */
public class NectoAndroidAppIdentity(context: Context) : NectoAppIdentity {
    private val context = context.applicationContext

    override val appBundleID: String get() = context.packageName

    override val appName: String
        get() = runCatching { context.applicationInfo.loadLabel(context.packageManager).toString() }
            .getOrDefault(context.packageName)

    override val appVersion: String
        get() = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull().orEmpty()

    /** The name the person gave the device, when it has one, otherwise the model. */
    override val deviceName: String
        get() = runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    /** The Android release, such as "15". The host prints it as "Android 15". */
    override val osVersion: String get() = Build.VERSION.RELEASE

    /** The launcher icon as PNG, at most [ICON_SIZE] pixels square. */
    override val appIcon: ByteArray?
        get() = runCatching {
            val drawable = context.packageManager.getApplicationIcon(context.packageName)
            png(drawable)
        }.getOrNull()

    private fun png(drawable: Drawable): ByteArray {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            Bitmap.createScaledBitmap(drawable.bitmap, ICON_SIZE, ICON_SIZE, true)
        } else {
            // Adaptive icons have no bitmap of their own; draw them.
            Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888).also { bitmap ->
                drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
                drawable.draw(Canvas(bitmap))
            }
        }
        return ByteArrayOutputStream().use { stream ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            stream.toByteArray()
        }
    }

    private companion object {
        const val ICON_SIZE = 192
    }
}
