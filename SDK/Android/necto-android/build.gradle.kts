// Copyright (c) 2026 Viva Republica, Inc.

plugins {
    id("com.android.library")
    kotlin("android")
    // For the Compose content in tests; main code has no composables.
    kotlin("plugin.compose")
    `maven-publish`
}

android {
    namespace = "im.toss.necto.android"
    compileSdk = 35

    defaultConfig {
        // java.util.Base64 and file creation times need API 26.
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    api(project(":necto-core"))
    api("androidx.datastore:datastore-preferences-core:1.1.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // Optional: read only when the app ships Compose, so View-only apps carry nothing extra.
    compileOnly("androidx.compose.ui:ui-android:1.7.8")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("androidx.activity:activity-compose:1.9.3")
    testImplementation("androidx.compose.foundation:foundation:1.7.8")
}

publishing {
    publications {
        create<MavenPublication>("release") {
            artifactId = project.name
            afterEvaluate { from(components["release"]) }
        }
    }
}
