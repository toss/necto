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

`script/android-connect` on the Mac does the rest. It refuses wireless ADB, reads the
name, runs `adb forward localfilesystem:<private path> localabstract:<name>`, and starts
Necto pointed at that path. It follows the app as it restarts and gets a new name.

```bash
script/android-connect <serial> <application id> --adb <adb> --host <Necto> --cli <necto-cli> \
    --state <run.json> --log <host.log>
```

`script/android-sample <serial>` builds the sample and Necto, installs the sample on a
USB device or a local emulator, and calls `android-connect` with everything filled in.

The device appears as `android:<serial>`, labelled `Android <version>`.

## Modules

| Module | Contents | iOS counterpart |
| --- | --- | --- |
| `necto-core` (plain JVM) | Protocol models, JSON and schema validation, framed message transport, coroutine SDK runtime, the shared part of the Events, Network, Performance, Files and UI Control plugins, web panels | `NectoModel`, `NectoTransport`, `NectoSDK`, `NectoDefaultPlugins` |
| `necto-android` | The ADB listener, app identity from `Context`, DataStore Preferences plugin, process sampler (CPU, PSS, FPS, threads), UI Control for Views and Jetpack Compose, default Files roots | `NectoProcessMetrics`, the UIKit parts |
| `necto-okhttp` | Network capture with an OkHttp `Interceptor` | `NectoURLSessionCapture` |

The Maven group and package root is `im.toss.necto`.

## Usage

```kotlin
val Context.settings by preferencesDataStore("settings")

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) {
            val events = NectoEventsPlugin()
            val network = NectoNetworkPlugin()
            NectoAndroid.start(
                this,
                NectoAndroidPlugins.defaults(this, events, network, dataStores = mapOf("settings" to settings)),
            )

            okHttpClient = OkHttpClient.Builder()
                .addInterceptor(NectoOkHttpInterceptor(network))
                .build()
            events.report(NectoEvent(NectoEvent.Level.INFO, "App", "started"))
        }
    }
}
```

`necto-android` declares no permissions. Custom plugins take the same shape as on iOS:

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
  - Dialogs and popups live in other windows and are not reached yet.
- **Panels** are packaged as Java resources: `necto/panels/<id>`, with a `files.txt`
  index.
  - The build generates them from the built iOS panels in
    `SDK/iOS/Sources/NectoDefaultPlugins/Panels`.
  - It overrides only the Control and Preferences manifests, which describe Android
    behaviour. They live in `necto-core/src/main/panel-manifests`, and the build fails
    when their contracts drift from the iOS ones.
- **Files writes** are bounded by the 64 KiB inbound frame, the limit `android-poc`
  set. A larger `files.write` closes the session, the request fails with
  `PROVIDER_FAILED`, and Necto reconnects within a second.

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
what was checked against a running app.
