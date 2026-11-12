// Copyright (c) 2026 Viva Republica, Inc.

plugins {
    id("com.android.library")
    kotlin("android")
    `maven-publish`
}

android {
    namespace = "im.toss.necto.datastore"
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
    implementation(project(":necto-plugin-support"))
    api("androidx.datastore:datastore-preferences-core:1.1.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation(kotlin("test-junit"))
}

val generatePanelResources by tasks.registering(NectoPanelResources::class) {
    panels.from(rootProject.fileTree("../iOS/Sources") {
        include("*/Panels/preferences/manifest.json")
    }.files.map { it.parentFile })
    ids.set(listOf("preferences"))
    manifests.set(layout.projectDirectory.dir("src/main/panel-manifests"))
    root.set("necto/panels")
    output.set(layout.buildDirectory.dir("generated/panelResources"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.resources?.addGeneratedSourceDirectory(generatePanelResources, NectoPanelResources::output)
    }
}

publishing {
    publications {
        create<MavenPublication>("release") {
            artifactId = project.name
            afterEvaluate { from(components["release"]) }
        }
    }
}
