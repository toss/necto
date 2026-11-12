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
        mavenCentral()
    }
}

rootProject.name = "necto-android"

include(":necto-core", ":necto-plugin-support", ":necto-events-plugin", ":necto-network-plugin", ":necto-performance-plugin", ":necto-okhttp-capture-plugin")

// Build the platform-independent reporting plugins without an Android SDK.
if (providers.gradleProperty("necto.skipAndroid").orNull != "true") {
    include(":necto-android", ":necto-files-plugin", ":necto-ui-control-plugin", ":necto-process-metric-plugin", ":necto-datastore-preferences-plugin", ":sample")
}
