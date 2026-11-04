// Copyright (c) 2026 Viva Republica, Inc.

plugins {
    id("com.android.application") version "8.7.3"
    kotlin("android") version "2.0.21"
}

android {
    namespace = "im.toss.necto.consumer"
    compileSdk = 35
    defaultConfig {
        applicationId = "im.toss.necto.consumer"
        minSdk = 26
        targetSdk = 35
    }
    flavorDimensions += "plugins"
    productFlavors {
        listOf("bridge", "network", "datastore", "control", "all").forEach { flavor ->
            create(flavor) {
                dimension = "plugins"
                applicationIdSuffix = ".$flavor"
            }
        }
    }
    buildTypes {
        getByName("debug") {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

val sdkVersion = providers.gradleProperty("necto.version").get()
val sdkGroup = providers.gradleProperty("necto.group").orElse("im.toss.necto").get()
configurations {
    create("networkDebugImplementation")
    create("datastoreDebugImplementation")
    create("controlDebugImplementation")
    create("allDebugImplementation")
}

dependencies {
    debugImplementation("$sdkGroup:necto-android:$sdkVersion")
    "networkDebugImplementation"("$sdkGroup:necto-okhttp:$sdkVersion")
    "datastoreDebugImplementation"("$sdkGroup:necto-datastore:$sdkVersion")
    "controlDebugImplementation"("$sdkGroup:necto-control:$sdkVersion")
    listOf("necto-events", "necto-okhttp", "necto-files", "necto-process-metrics", "necto-datastore", "necto-control").forEach {
        "allDebugImplementation"("$sdkGroup:$it:$sdkVersion")
    }
}

tasks.register("verifyDependencies") {
    doLast {
        val base = setOf("necto-core", "necto-android")
        val selections = mapOf(
            "bridge" to emptySet(),
            "network" to setOf("necto-network", "necto-okhttp", "necto-plugin-support"),
            "datastore" to setOf("necto-datastore", "necto-plugin-support"),
            "control" to setOf("necto-control", "necto-plugin-support"),
            "all" to setOf("necto-events", "necto-network", "necto-okhttp", "necto-files", "necto-performance", "necto-process-metrics", "necto-datastore", "necto-control", "necto-plugin-support"),
        )
        for ((flavor, plugins) in selections) {
            val modules = configurations["${flavor}DebugRuntimeClasspath"].resolvedConfiguration.resolvedArtifacts
                .map { it.moduleVersion.id }
            check(modules.filter { it.group == sdkGroup }.map { it.name }.toSet() == base + plugins) {
                "$flavor resolved unselected SDK modules: $modules"
            }
            check(modules.none { it.group.startsWith("androidx.compose") }) { "Compose must remain optional" }
            if (flavor !in setOf("datastore", "all")) check(modules.none { it.group.startsWith("androidx.datastore") })
            if (flavor !in setOf("network", "all")) check(modules.none { it.group == "com.squareup.okhttp3" })
            val release = configurations["${flavor}ReleaseRuntimeClasspath"].resolvedConfiguration.resolvedArtifacts
            check(release.none { it.moduleVersion.id.group in setOf(sdkGroup, "im.toss.necto") }) { "$flavor release carries Necto" }
        }
    }
}
