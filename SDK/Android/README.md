# Necto for Android

The app side of Necto for Android apps. An Android app speaks the same protocol (v1) as
an iOS app and carries the same web panels, so the Mac app shows it like any other
target.

## Connecting

The SDK does not open a network port. In a debuggable build, `NectoAndroid.start` binds
a Unix socket in the abstract namespace under a random name, `necto.<64 hex>`, and
writes that name to the app's private `no_backup/necto-endpoint`. Only ADB reaches it:

- The name is readable through `adb shell run-as <app>` alone, which needs a debuggable
  app.
- Any app could still connect to a name it knew, so the SDK accepts a connection only
  from the shell and root users that adbd runs as.
- In an app that is not debuggable, `start` logs a warning and does nothing.

Necto on the Mac does the rest, alongside its iOS connections, when the Android SDK is
installed. It finds `adb` through `ANDROID_HOME`, `ANDROID_SDK_ROOT` or
`~/Library/Android/sdk`, and starts the local adb server if none is running. Then, every
two seconds:

- It lists authorized devices on a USB cable and real local emulators. Wireless ADB is
  refused.
- On each, it asks the running third-party apps for their name through `run-as`.
- It forwards a private Unix socket to each name it finds (`adb forward
  localfilesystem:<private path> localabstract:<name>`) and connects there. An app that
  restarts under a new name is forwarded again; an app or device that goes away loses
  its forward.

`script/android-sample <serial>` builds the sample and a separate Necto, installs the
sample on a USB device or a local emulator, and runs that Necto until Ctrl-C.

The device appears as `android:<serial>`, labelled `Android <version>`.

## Modules

`necto-android` supplies the Android connection and depends only on `necto-core` and
coroutines. It carries no feature panels, DataStore, OkHttp or Compose. Add and register
only the plugins the app needs; `NectoAndroid.start(context)` alone starts the bridge
without registering any plugins.

| Artifact | Contents / entry point |
| --- | --- |
| `necto-core` | Protocol models, transport, plugin contracts and SDK runtime (plain JVM) |
| `necto-android` | ADB listener and app identity: `NectoAndroid.start(context, plugins)` |
| `necto-events-plugin` | Events reporting and panel: `NectoEventsPlugin` |
| `necto-network-plugin` | Network reporting and panel: `NectoNetworkPlugin`; no capture dependency |
| `necto-okhttp-capture-plugin` | Optional OkHttp capture: `OkHttpNetworkPlugin` or `NectoOkHttpInterceptor`; depends on `necto-network-plugin` |
| `necto-files-plugin` | Files panel and selected roots: `NectoFilesPlugin(context)` or `NectoFilesPlugin(roots)` |
| `necto-performance-plugin` | Custom metric reporting and panel: `NectoPerformancePlugin`; no process sampler |
| `necto-process-metric-plugin` | Optional Android process sampling: `NectoProcessMetricPlugin(context)`; depends on `necto-performance-plugin` |
| `necto-ui-control-plugin` | Views and optional Compose UI Control: `NectoAndroidControlPlugin(context)` |
| `necto-datastore-preferences-plugin` | DataStore Preferences and panel: `NectoDataStorePreferencesPlugin(stores)` |

`necto-plugin-support` is an implementation dependency shared by the feature modules.
It contains resource loading, stream fan-out and text decoding helpers, with no panel
or capture mechanism. Apps do not need to declare it directly. Each feature artifact
carries only its own panel. Compose remains `compileOnly` in Control.

The Kotlin package root is `im.toss.necto`. JitPack publishes the modules under
`com.github.toss.necto`; local publications default to `im.toss.necto`.

## JitPack

The root `jitpack.yml` uses JDK 17 and runs `publishToMavenLocal` in `SDK/Android`.
Every module with a Maven publication is included; the sample app is not published.
The build uses JitPack's group and requested tag/commit for both the publications and
their inter-module dependencies, including Gradle module metadata.

Add JitPack to `settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://jitpack.io")
            content { includeGroup("com.github.toss.necto") }
        }
    }
}
```

Use a commit containing the Android SDK or a tag made from it. Pin that version for
all selected modules. Use the individual module coordinates below; JitPack's aggregate
`com.github.toss:necto` dependency includes every module and defeats selective adoption.
See [JitPack's multi-module documentation](https://docs.jitpack.io/building/#multi-module-projects).

## Usage

For example, to include Events in debug builds only:

```kotlin
// app/build.gradle.kts
val nectoVersion = "COMMIT_OR_TAG"
dependencies {
    debugImplementation("com.github.toss.necto:necto-android:$nectoVersion")
    debugImplementation("com.github.toss.necto:necto-events-plugin:$nectoVersion")
}
```

Keep SDK references in the debug source set. A `BuildConfig.DEBUG` condition in
`src/main` does not remove those references from release compilation.

```kotlin
// src/debug/kotlin/com/example/NectoSetup.kt
package com.example

import android.app.Application
import im.toss.necto.android.NectoAndroid
import im.toss.necto.plugins.NectoEventsPlugin

object NectoSetup {
    fun start(app: Application) {
        NectoAndroid.start(app, listOf(NectoEventsPlugin()))
    }
}
```

```kotlin
// src/release/kotlin/com/example/NectoSetup.kt
package com.example

import android.app.Application

object NectoSetup {
    fun start(app: Application) = Unit
}
```

Call `NectoSetup.start(this)` from the app's `Application.onCreate`. Release builds
compile without any Necto dependency. Add a matching setup for other build types as
needed. For network capture, add `necto-okhttp-capture-plugin` to the debug
dependencies and wire the same instance to the bridge and the app's client:

```kotlin
val network = OkHttpNetworkPlugin()
NectoAndroid.start(app, listOf(network))
val client = OkHttpClient.Builder()
    .addInterceptor(network.interceptor)
    .build()
```

To inspect DataStore, add `necto-datastore-preferences-plugin` and register
`NectoDataStorePreferencesPlugin(mapOf("settings" to app.settings))` with the app's own
store. Neither the connection nor other plugins bring DataStore into the app.

### Migrating the Android preview

The former `NectoAndroidPlugins` factory and automatic defaults are removed. Select
artifacts and pass an explicit plugin list. Replace `files(context)` with
`NectoFilesPlugin(context)`, `control(context)` with `NectoAndroidControlPlugin(context)`,
and `performance(context)` with `NectoProcessMetricPlugin(context)`. Activity tracking
now belongs to Control and starts only when that plugin is created. Existing reporting
plugin classes and wire contracts are unchanged.

Add the interceptor after any interceptor that checks a request body's type, such as
one that adds fields to a `FormBody`: the interceptor wraps the body to copy the bytes
OkHttp sends, so interceptors after it see the wrapper. An interceptor before it that
compresses the body is captured compressed.

The SDK modules declare no permissions. Custom plugins take the same shape as on iOS:

```kotlin
class ThingsPlugin : NectoPlugin {
    override val id = "com.example.things"
    override fun register(necto: NectoRegistrar) {
        necto.handle("things.list") { jsonObject("things" to jsonArray(...)) }
        necto.stream("things.observe") { _, out -> changes.collect { out.send(it) } }
    }
}
```

## The connection is not trusted

Whatever reaches the socket is treated as hostile, and a session that misbehaves is
closed. The listener keeps waiting, so the next connection works without restarting the
app.

| Limit | Value |
| --- | --- |
| Inbound frame | 1 byte to 64 KiB |
| Outbound frame | 32 MiB, the size the Mac reads |
| A started frame, and every write | 10 seconds |
| Handshake answer | 5 seconds, 4 KiB |
| JSON | Strict UTF-8, nesting depth 64, nothing after the value |
| Active requests | 32 per session, request IDs of 1 to 128 characters, no duplicates |

One session is served at a time.

## Differences from iOS

- **Preferences**: Jetpack DataStore Preferences instead of `UserDefaults`.
  - DataStore allows one instance per file, so the app hands over its own instances by
    name (`dataStores = mapOf("settings" to context.settings)`). The first is the default
    store.
  - Long and Float values are edited as Int and Double in the panel and keep their
    stored type.
  - ByteArray values are read-only.
- **Files roots**: `files`, `cache`, `data` (including `shared_prefs` and `databases`),
  `external`, `external-cache`.
- **Performance**: `memory` is total PSS, `resident-memory` is VmRSS, and
  `compressed-memory` is VmSwap (zram). `java-heap` and `native-heap` are added.
- **UI Control**:
  - It reads the View tree and, when the app has Compose, each host's Jetpack Compose
    semantics tree. Compose is `compileOnly`, so View-only apps carry nothing extra.
  - Coordinates are in pixels.
  - Back is the system BACK key (`method: "backKey"`).
  - Overlays that take no touches, such as edge-to-edge's `ProtectionLayout`, do not
    count as covering what is below.
  - Dialogs and popups live in other windows and are not reached yet. While one holds
    input focus, Control offers no targets, refuses actions and reads no accessibility
    items. A multi-tap or a text input stops when its first tap opens one.
  - Inside a Compose host, an element covers what is below it when it has touch
    semantics (click, scroll or text input). A bare `pointerInput` and `zIndex` are not
    seen.
  - A tap reaches a clickable parent only where no child that takes taps covers it, in
    Views and in Compose, since that child would run its own click instead. A swipe
    still scrolls the list it starts in.
- **Panels** are packaged as Java resources: `necto/panels/<id>`, with a `files.txt`
  index.
  - The build generates them from the built panel beside each module,
    `SDK/Plugins/<Name>/Panel`, the same directory the Swift package copies.
  - It overrides only the Control and Preferences manifests, which describe Android
    behaviour. They live in each owning plugin's `src/main/panel-manifests`, and the build fails
    when their contracts drift from the panel's own.
- **Requests from Necto** are bounded by the 64 KiB inbound frame, which reaches
  `files.write` and `preferences.set` with a large string. A larger request closes
  the session, the request fails with `PROVIDER_FAILED`, and Necto reconnects within a
  second.

## Sample app

`sample` ports Necto's iOS `ExampleApp` screen by screen, in Jetpack Compose with five
tabs.

| Tab | Contents | iOS counterpart |
| --- | --- | --- |
| Connection | SDK status, protocol version, stop and start listening | `ConnectionView` |
| Network | Sample requests to a loopback REST server inside the app (`LocalApi`): GET, POST, PATCH, DELETE, a large response, a slow response, 404, 500, a DNS failure | `NetworkView`, `LocalAPI` |
| Control | The UI Control fixture in both Compose and Views (`AndroidView`), switched with chips. Labels and identifiers (`poc.*`) match iOS | `ControlFixtureController` |
| Accessibility | Compose fixture (`ax.*`): counter, disabled button, text field, detail, sheet, custom scroll | `AccessibilityFixture` |
| About | SDK and protocol versions | `AboutView` |

The custom plugin `plugin-sample` (`com.example.app.state`, `com.example.app.counter`)
carries the same web panel as `ExampleApp`. The build copies it from
`WebPackages/BuiltInPlugins/Plugins`. On launch the app seeds DataStore Preferences and
`files/` with example values and files.

## Building

Build the web panels first (`script/build` does), because the Android build packages
them.

```bash
./gradlew build                          # everything (needs Google Maven)
./gradlew -Pnecto.skipAndroid=true test  # JVM modules only
```

minSdk 26, compileSdk 35, Kotlin 2.0.21, AGP 8.7.3, JDK 17.

## Verification

[docs/verification.md](docs/verification.md) lists what the automated tests cover, and
what was checked against a running app. From the repository root,
`script/test-android-consumer` publishes to a local test repository and builds independent,
minified apps selecting only the bridge, OkHttp, DataStore, Control or all plugins without
Compose. It checks resolved dependencies, packaged panels and a release build without
Necto. To verify a remote JitPack build without publishing locally, run:

```bash
script/test-android-consumer --jitpack COMMIT_OR_TAG
```

For a local coordinate check, pass `-- -Pnecto.group=com.github.toss.necto
-Pnecto.version=jitpack-test`. The same check validates the generated Maven dependencies
before pushing a commit.
