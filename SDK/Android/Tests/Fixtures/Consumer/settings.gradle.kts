// Copyright (c) 2026 Viva Republica, Inc.

pluginManagement {
    repositories {
        google()
        // As in SDK/Android/settings.gradle.kts: CI asks a mirror of Maven Central first.
        if (System.getenv("CI") != null) {
            maven("https://maven-central.storage-download.googleapis.com/maven2/") { name = "MavenCentralMirror" }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        maven {
            url = uri(providers.gradleProperty("necto.repository").get())
            content { includeGroup(providers.gradleProperty("necto.group").orElse("im.toss.necto").get()) }
        }
        google()
        if (System.getenv("CI") != null) {
            maven("https://maven-central.storage-download.googleapis.com/maven2/") { name = "MavenCentralMirror" }
        }
        mavenCentral()
    }
}

rootProject.name = "necto-sdk-consumer"
