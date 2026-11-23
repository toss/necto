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

// The oldest Ktor 3 release, built with the Kotlin this SDK uses. An app on a newer Ktor 3
// resolves its own version, and the capture uses only API that newer releases keep.
val ktorVersion = "3.0.3"

// Runs the tests against a newer Ktor than the one compiled against, as an app would:
// `-Pnecto.ktorTestVersion=3.6.1`.
val ktorTestVersion = providers.gradleProperty("necto.ktorTestVersion").orNull

dependencies {
    api(project(":necto-network-plugin"))
    api("io.ktor:ktor-client-core:$ktorVersion")
    testImplementation(kotlin("test"))
    testImplementation("io.ktor:ktor-client-mock:$ktorVersion")
    testImplementation("io.ktor:ktor-client-encoding:$ktorVersion")
}

if (ktorTestVersion != null) {
    configurations.named("testRuntimeClasspath") {
        resolutionStrategy.eachDependency {
            if (requested.group == "io.ktor") useVersion(ktorTestVersion)
        }
    }
}

tasks.test {
    useJUnitPlatform()
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            artifactId = project.name
            from(components["java"])
        }
    }
}
