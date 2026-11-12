// Copyright (c) 2026 Viva Republica, Inc.

pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}

dependencyResolutionManagement {
    repositories {
        maven {
            url = uri(providers.gradleProperty("necto.repository").get())
            content { includeGroup(providers.gradleProperty("necto.group").orElse("im.toss.necto").get()) }
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "necto-sdk-consumer"
