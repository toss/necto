// Copyright (c) 2026 Viva Republica, Inc.

plugins {
    `kotlin-dsl`
}

repositories {
    if (System.getenv("CI") != null) {
        maven("https://maven-central.storage-download.googleapis.com/maven2/") { name = "MavenCentralMirror" }
    }
    mavenCentral()
}
