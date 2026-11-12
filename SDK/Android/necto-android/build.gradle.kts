// Copyright (c) 2026 Viva Republica, Inc.

plugins {
    id("com.android.library")
    kotlin("android")
    `maven-publish`
}

android {
    namespace = "im.toss.necto.android"
    compileSdk = 35

    defaultConfig {
        // java.util.Base64 and file creation times need API 26.
        minSdk = 26
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
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
}

publishing {
    publications {
        create<MavenPublication>("release") {
            artifactId = project.name
            afterEvaluate { from(components["release"]) }
        }
    }
}
