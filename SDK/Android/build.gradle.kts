// Copyright (c) 2026 Viva Republica, Inc.

plugins {
    // Declared once so every module shares the same plugin classloader. The Android Gradle
    // Plugin must sit next to the Kotlin Gradle Plugin here, otherwise KGP cannot see AGP
    // classes (BaseVariant) when kotlin("android") is applied in necto-android.
    id("com.android.library") version "8.7.3" apply false
    id("com.android.application") version "8.7.3" apply false
    kotlin("jvm") version "2.0.21" apply false
    kotlin("android") version "2.0.21" apply false
    kotlin("plugin.compose") version "2.0.21" apply false
}

allprojects {
    group = "im.toss.necto"
    version = "0.1.0"
}
