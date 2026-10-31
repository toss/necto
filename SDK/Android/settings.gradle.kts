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

include(":necto-core")
include(":necto-okhttp")

// The Android library needs the Android Gradle Plugin from Google's Maven. Pass
// -Pnecto.skipAndroid=true where that is unreachable to build the JVM modules alone.
if (providers.gradleProperty("necto.skipAndroid").orNull != "true") {
    include(":necto-android")
    include(":sample")
}
