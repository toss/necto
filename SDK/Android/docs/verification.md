# Verification

What was checked, and how to check it again. Update it when behaviour changes.

## Automated tests

`./gradlew build` runs them all.

| Module | Tests | What they cover |
| --- | --- | --- |
| necto-core | 28 | Protocol models and JSON, schema validation, the shipped panel manifests, SDK runtime, plugin behaviour. The runtime tests feed it a hostile peer: frames outside 1 byte to 64 KiB, nesting past 64, invalid UTF-8, trailing JSON, a stalled frame, a silent handshake, an oversized handshake answer, long or duplicate request IDs and more than 32 active requests. Each closes the session, and the next connection works |
| necto-okhttp | 7 | Request and response capture, capped large bodies, failures and `RuntimeException`s, streams that are not held back, bodies closed unread, large uploads |
| necto-android | 12 (9 Robolectric) | UI Control on Views and Compose: listing with labels, test tags, values and secure fields; tap, text input (replace and append) and swipe on Compose; a touch-transparent full-window overlay does not hide content, while a clickable one does. The frame rate is left out until a full second has been measured. DataStore Preferences: a Long a JSON number would round (2^53 and beyond) is shown read-only and not written back rounded |

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

## Earlier device checks

The plugins were first checked on a Samsung Galaxy S25+ (Android 17, USB) and a
production Jetpack Compose app, against Necto 0.2.0, before the SDK moved to the ADB
socket. Plugin behaviour does not depend on the transport, but these have not been
repeated over the new connection.

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
  Control.
- An app that is not in the foreground has no UI Control targets.
- `files.write` is bounded by the 64 KiB inbound frame. On a Galaxy S25+, 32 KiB and
  60 KiB writes succeed; a 100 KiB write closes the session with `PROVIDER_FAILED`, and
  the target reconnects in under a second.
- One session is served at a time.
