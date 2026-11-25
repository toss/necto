// Copyright (c) 2026 Viva Republica, Inc.

// buildSrc is its own build and takes no repositories from ../settings.gradle.kts.
pluginManagement {
    repositories {
        // As in ../settings.gradle.kts: CI asks a mirror of Maven Central first.
        if (System.getenv("CI") != null) {
            maven("https://maven-central.storage-download.googleapis.com/maven2/") { name = "MavenCentralMirror" }
        }
        gradlePluginPortal()
    }
}
