# Verification

What was checked, and how to check it again. Update it when behaviour changes.

## Automated tests

`./gradlew build` runs them all.

| Modules | Coverage |
| --- | --- |
| `necto-core` | Protocol, JSON, schema validation, runtime lifecycle, request limits and plugin routing, with Events and Network as test-only consumers |
| `necto-network`, `necto-okhttp` | Reporting, cURL quoting, truncated UTF-8, upload/response capture, failures and streaming bodies |
| `necto-files` | Listing, previews, writes, path containment and deleting links without entering their targets |
| `necto-performance`, `necto-process-metrics` | Custom series and budgets, failing sampler cleanup and initial frame-rate availability |
| `necto-control` | Geometry, Views and Compose discovery/actions, cancellation, coverage and other-window focus |
| `necto-datastore` | Numeric precision/range preservation and string-set round trips |
| `sample` | Every selected plugin's packaged manifest validates and its panel loads |

`script/test-android-artifacts` checks that every plugin owns its panel, the bridge
carries no feature implementation or panel, and no SDK AAR declares a permission.
`script/test-android-consumer` publishes the artifacts to a local repository and builds
five independent minified consumers. The bridge consumer has no plugins; OkHttp,
DataStore and Control consumers resolve only their selected feature; an all-plugins
consumer resolves all eleven SDK modules. None includes
Compose, and release builds have no Necto dependency. The fixture's bridge release
also compiles to catch SDK references accidentally placed in shared sources.
`script/test-android-consumer --jitpack <tag-or-commit>` runs the same consumer checks
against JitPack artifacts without publishing to or using the local test repository.

The overlay test fails when the hit test treats every visible view as a blocker.

## Against a running app

`script/android-sample <serial>` builds the sample and Necto, installs the sample and
connects the two. The scripts below then run against it. The repository's
[docs/verification.md](../../../docs/verification.md) describes each one.

Run on an Android 17 emulator (`sdk_gphone64_arm64`, API 37) on an Apple silicon Mac:

| Script | Result |
| --- | --- |
| `script/test-android-sample` | ✅ The target appears as `android:emulator-5554`. Every shipped panel's operations are available. `events.detail` answers. `{"limit":0}` is refused with `INVALID_INPUT`. A `performance.observe` stream ends and a new one starts. `files.roots` and `preferences.suites` answer. `events.clear` works. A force stop ends an open stream with `TARGET_DISCONNECTED` and removes the target, and a relaunch brings it back |
| `script/test-android-security` | ✅ A silent handshake is dropped after 5 seconds. Frames of 0 bytes, 64 KiB + 1 and 4 GiB are dropped, as are nesting past 64, a frame that stalls for 10 seconds, and 33 concurrent requests. A request then succeeds without restarting the app |
| `script/test-android-artifacts` | ✅ `necto-android` declares no permission. 24 packaged panel files equal the iOS ones. Only the debug sample is debuggable |

Repeated over USB on a Samsung Galaxy S25+ (`SM-S936N`, Android 17, API 37):
`script/test-android-sample` and `script/test-android-security` both pass, with the
target appearing as `android:<serial>`.

The Control fixture and a string set edit were then driven over the ADB socket through
`necto-cli`, three runs on each of the emulator and the Galaxy S25+: on Compose and on
Views, `poc.readonly` and `poc.trap` are not targets, two taps, the nav action, the
switch row, a tap at a position that leaves the trap alone, opening detail and going
back, and a swipe that scrolls `poc.scroll`. `example.interests` reads as `StringSet`,
and rows `1.0`, `"x"`, `1`, `true`, `{"a":1}` and `한글` are stored as typed; removing
`1` removes only that row.

Necto finds the app through ADB itself. It connected 3.7 seconds after it started
with the app already running, and 6.2 seconds after the app was restarted. On start,
Necto removes forwards left by a run that was killed, and leaves those of another
Necto that is still running.

## Earlier device checks

The plugins were first checked on a Samsung Galaxy S25+ (Android 17, USB) and a
production Jetpack Compose app, against Necto 0.2.0, before the SDK moved to the ADB
socket. Plugin behaviour does not depend on the transport, but only Control and Preferences
have been repeated over the new connection (above).

| Plugin | Check |
| --- | --- |
| Network | OkHttp requests listed with status, duration, size, headers, body and cURL; a production app's login and data requests listed live |
| Preferences | Every DataStore listed by name; `preferences.set` updates the running app's UI |
| Files | `files.roots`, `files.list` on the app's data directory |
| Performance | CPU, memory, FPS (about 120 on a 120 Hz display while scrolling), threads, Java and native heap |
| Control (Views, Compose) | The sample's Control fixture, the same 14 steps on each: `poc.readonly` and `poc.trap` are not targets; tap twice; a nav action; replace, then append Korean text; a secure password field whose input still lands; notes; switch; tap at a position; two fingers twice; swipe scrolls `poc.scroll`; open detail, then back |
| Control (Compose) | Elements hidden by the keyboard or scrolled out are not targets until scrolled back; a production login screen's buttons are listed under androidx.core's `ProtectionLayout` |
| Accessibility | The disabled button and read-only text are not targets; count tap; the sheet opens and hides the background; back closes it |
| Network | "Run every request" against the in-app API: GET, POST, PATCH, DELETE (204), a large response, a slow response, 404, 500, and an unresolvable host recorded as failed |

## Known limitations

- Dialogs, popups and bottom sheets live in other windows and are not reached by UI
  Control. While one holds input focus, UI Control offers no targets, refuses actions
  and reads no accessibility items, rather than acting on the activity behind it.
- In Compose, an element that takes touches without semantics, such as a bare
  `pointerInput`, does not count as covering what is below, and neither does `zIndex`.
- An app that is not in the foreground has no UI Control targets.
- Requests from Necto are bounded by the 64 KiB inbound frame. This reaches
  `files.write` and `preferences.set` with a large string or string set.
  `files.write` is the one measured: on a Galaxy S25+, 32 KiB and
  60 KiB writes succeed; a 100 KiB write closes the session with `PROVIDER_FAILED`, and
  the target reconnects in under a second.
- One session is served at a time.
