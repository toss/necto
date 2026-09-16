# Android SDK preview

Necto's Android SDK connects a debuggable application to the Mac host. Device plugins
implement `NectoPluginable`, register JSON contracts, and optionally carry a web panel
in their AAR. The existing Events panel and protocol v1 are shared with iOS.

## Modules and adoption

- `sdk`: private local sockets, framing, handlers, streams and panel transport.
- `events`: bounded event history and the existing `events.*` contracts and panel.
- `sample`: debug-only application, button events and foreground heartbeat.

Use a project dependency while developing locally:

```kotlin
dependencies { debugImplementation(project(":events")) }
```

In the application's **debug source set**, retain the SDK and plugin for the app's
lifetime, then initialize them from `Application.onCreate()`:

```kotlin
val events = DefaultEventsPlugin(this)
val necto = NectoSDK(this, listOf(events))
necto.start()
events.report("Screen opened", tag = "Navigation")
```

Register custom plugins in the same list. Registration is fixed for that SDK instance.
`close()` disconnects and releases the endpoint; create a new instance to restart.
One instance may listen per application, including across its processes. Keep the
SDK in the main app process. `start()` reports binding/ownership failures to its caller.
The SDK rejects non-debuggable apps before registering handlers. Do not include it
with `implementation` in a customer application. A release AAR is a library build
artifact, not permission to run inside a non-debuggable application.

## Connection and trust

Both ends use Unix sockets. No Android TCP listener or `INTERNET` permission is needed.

1. The app creates a fresh random abstract socket and writes its name atomically to
   `no_backup/necto-endpoint` with mode `0600`, under its private app directory.
2. The launcher reads that name with authorized ADB `run-as APPLICATION_ID`.
3. ADB forwards a Mac socket inside a mode `0700` directory to the app's socket.
4. The SDK checks kernel peer credentials and admits only shell/root (adbd), before
   sending app metadata. Ordinary app UIDs are refused, including the app's own UID.
5. The host checks ownership and privacy of the Mac endpoint and verifies the hello's
   application ID against the application selected by the launcher.

The launcher accepts local emulators and transports reported by ADB as USB. Wireless
ADB is refused, including mDNS-named devices. It follows endpoint rotation after app
restarts and recreates forwarding after device/ADB disconnection. The Mac keeps the
existing app session and reconnection machinery. No iOS handshake change is required.

Trust includes the selected debug app and its plugins, the developer's Mac and ADB
server, and authorized ADB/root/shell access on the device. A compromised ADB server,
rooted device, or process controlling that server is outside this boundary. Socket
privacy does not remove the privileges already granted to ADB. There is no custom
cryptographic protocol or claim of end-to-end encryption.

The Mac verifies panel hashes and archive paths and applies manifest-based CSP to
web requests. Hashes verify content consistency, not publisher identity. Native
bridge permissions remain separate. Only ship trusted plugins and explicitly approve
any remote origins they need. The host's CSP applies to iOS and Android panels alike;
see [the manifest contract](../docs/plugin-manifest.md).

## Run locally

Requirements: Xcode, JDK 17+, Android SDK 35, Python 3, and a running local emulator
or an authorized USB device with USB debugging and `run-as` support. Minimum Android
API is 26. Dependencies use Google Maven and Maven Central.

```bash
export ANDROID_HOME=/path/to/android/sdk
"$ANDROID_HOME/platform-tools/adb" devices -l
script/android-poc emulator-5554
```

Replace `emulator-5554` with the actual USB serial for a physical device. The launcher
builds the sample and Mac host, installs only `dev.necto.sample`, and opens an Android-only
host with isolated settings. Existing iOS host sessions are not touched. A local SDK
under `Build/AndroidTools/sdk` and Android Studio's JDK are accepted as fallbacks.
Use `--no-build` as the second argument to reuse built artifacts.

For a custom app, start its SDK, then use `script/android-connect --help`: specify
its serial, application ID, local `adb`, host/CLI executables and state/log paths.
This command performs no build or app installation. The selected app must already
be installed and debuggable. Mac host binaries must include this Android adapter.

Keep the launcher running. Ctrl-C terminates its host and removes forwarding. The
app/emulator and private host settings remain. The endpoint name is never printed
or stored in host state; the state file records only the private Mac socket path.

## Limits

- One selected device and app per launcher; no automatic device picker or hot registration.
- Requests: 64 KiB; handshake acknowledgment: 4 KiB; JSON nesting: 64; replies: 32 MiB.
- At most 32 simultaneous requests. An invalid frame or excess requests closes the
  connection. A partial frame or stalled write has a 10-second deadline. Handshake
  timeout is 5 seconds; single-response handlers have a cooperative 30-second timeout.
  Idle established connections and streams do not expire. Plugins must cooperate
  with coroutine cancellation and avoid blocking handler work.
- Events retains at most 5,000 records and 8 MiB of serialized history. Messages are
  limited to 1,024 characters, tags to 128, and details to 16 entries (64-character
  keys, 256-character values). Slow stream collectors can lose older live updates.
- Captured data is not automatically redacted. Apps choose which data to report.
- Network capture, View/Compose inspection, preferences and performance plugins are
  not part of this Android implementation.

## Verify before distribution

```bash
Android/gradlew -p Android :sdk:testDebugUnitTest :sdk:connectedDebugAndroidTest \
  :sdk:lintDebug :events:lintDebug :sample:assembleDebug :sample:assembleRelease \
  :sdk:assembleRelease :events:assembleRelease
script/test-android-artifacts
script/test swift
script/test native
```

Set `ANDROID_SERIAL` to limit instrumented tests to the intended emulator/device.
The artifact check verifies release exclusion, permissions, and the carried panel bytes.
The instrumentation tests exercise real kernel UID rejection, endpoint permissions,
rotation, cleanup and duplicate SDK ownership. Release AARs are built under each
module's `build/outputs/aar/`; dependency resolution must still accompany these AARs.
No Maven repository or publication task is configured.

With the sample launcher running:

```bash
script/test-android-security
script/test-android-poc
```

The security check temporarily pauses only the recorded POC host and restarts only
`dev.necto.sample`. It sends malformed/oversized frames, stalls handshake and payloads,
exceeds the request quota, then verifies recovery. The functional check exercises
actual button events, details, streams/cancellation, clear, disconnect and reconnect.
Results live under `Build/AndroidPOC/`. CLI checks do not prove web rendering; inspect
the Events panel as well. WebKit integration tests verify CSP enforcement.

**Release gates still requiring hardware/environment evidence:** physical USB on a
non-root user build, unplug/replug and authorization revocation, the minimum supported
Android version and representative OEMs, and iOS ExampleApp connection E2E after
shared host changes. Emulator and unit-test results do not replace those checks.
This branch is a hardened developer preview; it is not a completed release certification.
