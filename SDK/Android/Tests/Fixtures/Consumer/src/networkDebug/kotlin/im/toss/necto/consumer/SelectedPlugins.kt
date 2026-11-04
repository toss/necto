// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.consumer

import android.app.Application
import im.toss.necto.sdk.NectoPlugin
import im.toss.necto.okhttp.OkHttpNetworkPlugin
import okhttp3.OkHttpClient

fun selectedPlugins(app: Application): List<NectoPlugin> = listOf(OkHttpNetworkPlugin().also { plugin ->
    OkHttpClient.Builder().addInterceptor(plugin.interceptor).build()
})
