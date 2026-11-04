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
    api(project(":necto-core"))
    implementation(project(":necto-plugin-support"))
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}

val generatePanelResources by tasks.registering(NectoPanelResources::class) {
    panels.from(rootProject.fileTree("../iOS/Sources") {
        include("*/Panels/network-logger/manifest.json")
    }.files.map { it.parentFile })
    ids.set(listOf("network-logger"))
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
