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

include(":necto-core", ":necto-plugin-support", ":necto-events", ":necto-network", ":necto-performance", ":necto-okhttp")

// Build the platform-independent reporting plugins without an Android SDK.
if (providers.gradleProperty("necto.skipAndroid").orNull != "true") {
    include(":necto-android", ":necto-files", ":necto-control", ":necto-process-metrics", ":necto-datastore", ":sample")
}
