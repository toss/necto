plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
val panelAssets = tasks.register<Sync>("preparePanelAssets") {
    from("../../Sources/NectoDefaultPlugins/Panels/event-log")
    into(layout.buildDirectory.dir("generated/nectoAssets/event-log"))
}
android {
    namespace = "dev.necto.events"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/nectoAssets"))
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
tasks.named("preBuild") { dependsOn(panelAssets) }
dependencies { api(project(":sdk")) }
