// Copyright (c) 2026 Viva Republica, Inc.

plugins {
    id("com.android.application")
    kotlin("android")
    kotlin("plugin.compose")
}

android {
    namespace = "im.toss.necto.sample"
    compileSdk = 35

    defaultConfig {
        applicationId = "im.toss.necto.sample"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// Built from WebPackages/BuiltInPlugins: the same plugin-sample panel ExampleApp carries.
val generatePanelResources by tasks.registering(NectoPanelResources::class) {
    panels.set(rootProject.layout.projectDirectory.dir("../../WebPackages/BuiltInPlugins/Plugins"))
    ids.set(listOf("plugin-sample"))
    root.set("panels")
    output.set(layout.buildDirectory.dir("generated/panelResources"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.resources?.addGeneratedSourceDirectory(generatePanelResources, NectoPanelResources::output)
    }
}

dependencies {
    implementation(project(":necto-android"))
    implementation(project(":necto-okhttp"))
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation(platform("androidx.compose:compose-bom:2025.02.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.9.3")
}
