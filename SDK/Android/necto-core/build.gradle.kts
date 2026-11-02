// Copyright (c) 2026 Viva Republica, Inc.

plugins {
    kotlin("jvm")
    `java-library`
    `maven-publish`
}

java {
    withSourcesJar()
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}

// The iOS SDK's built panels, carried unchanged apart from the manifests in
// src/main/panel-manifests. `yarn build` in WebPackages writes them.
val generatePanelResources by tasks.registering(NectoPanelResources::class) {
    panels.set(rootProject.layout.projectDirectory.dir("../iOS/Sources/NectoDefaultPlugins/Panels"))
    ids.set(listOf("control", "event-log", "files", "network-logger", "performance-monitor", "preferences"))
    manifests.set(layout.projectDirectory.dir("src/main/panel-manifests"))
    root.set("necto/panels")
    output.set(layout.buildDirectory.dir("generated/panelResources"))
}

sourceSets.main {
    resources.srcDir(generatePanelResources)
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            artifactId = project.name
            from(components["java"])
        }
    }
}
