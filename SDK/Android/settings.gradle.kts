// Copyright (c) 2026 Viva Republica, Inc.

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        // Maven Central rate limits hosted CI runners with 429 responses, so CI asks Google's
        // mirror of it first. The mirror syncs about once a day, and what it does not have
        // yet is still found on Maven Central after the mirror answers 404. Not for local
        // builds: a mirror that cannot be reached fails the build instead of falling through.
        if (System.getenv("CI") != null) {
            maven("https://maven-central.storage-download.googleapis.com/maven2/") { name = "MavenCentralMirror" }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        if (System.getenv("CI") != null) {
            maven("https://maven-central.storage-download.googleapis.com/maven2/") { name = "MavenCentralMirror" }
        }
        mavenCentral()
    }
}

rootProject.name = "necto-android"

include(":necto-core", ":necto-plugin-support", ":necto-events-plugin", ":necto-network-plugin", ":necto-performance-plugin", ":necto-okhttp-capture-plugin", ":necto-ktor-capture-plugin")

// Build the platform-independent reporting plugins without an Android SDK.
if (providers.gradleProperty("necto.skipAndroid").orNull != "true") {
    include(":necto-android", ":necto-files-plugin", ":necto-ui-control-plugin", ":necto-process-metric-plugin", ":necto-datastore-preferences-plugin", ":sample")
}

// A plugin lives beside its panel and its iOS counterpart, in SDK/Plugins/<Name>/Android.
mapOf(
    "necto-events-plugin" to "Events",
    "necto-network-plugin" to "Network",
    "necto-okhttp-capture-plugin" to "OkHttpCapture",
    "necto-ktor-capture-plugin" to "KtorCapture",
    "necto-files-plugin" to "Files",
    "necto-performance-plugin" to "Performance",
    "necto-process-metric-plugin" to "ProcessMetric",
    "necto-ui-control-plugin" to "UIControl",
    "necto-datastore-preferences-plugin" to "Preferences",
).forEach { (name, plugin) ->
    findProject(":$name")?.projectDir = file("../Plugins/$plugin/Android")
}
