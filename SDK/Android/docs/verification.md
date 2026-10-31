# Verification

What was checked, and how to check it again. Update it when behaviour changes.

## Automated tests

`./gradlew build` runs them all.

| Module | Tests | What they cover |
| --- | --- | --- |
| necto-core | 33 | Protocol models and JSON, schema validation, the shipped panel manifests, SDK runtime, plugin behaviour, including a folder deleted without following the links inside it, a link deleted as a link, and a body cut mid-character that keeps its text. The runtime tests feed it a hostile peer: frames outside 1 byte to 64 KiB, nesting past 64, invalid UTF-8, trailing JSON, a stalled frame, a silent handshake, an oversized handshake answer, long or duplicate request IDs and more than 32 active requests. Each closes the session, and the next connection works |
| necto-okhttp | 10 | Request and response capture, an upload captured as it is sent, a body that closes its sink, capped large bodies, failures and `RuntimeException`s, a body that fails to read recorded as failed, streams that are not held back, bodies closed unread, large uploads, a cURL command that quotes every part |
| necto-android | 22 (17 Robolectric) | UI Control on Views and Compose: listing with labels, test tags, values and secure fields; tap, text input (replace and append) and swipe on Compose; a cancelled tap or swipe sends ACTION_CANCEL; a Compose element covered inside its host is not touched; a clickable parent, View or Compose, is not tapped where a clickable child inside it takes the tap; nothing is acted on while another window has focus, including a second tap after the first opened a dialog; a touch-transparent full-window overlay does not hide content, while a clickable one does. The frame rate is left out until a full second has been measured. DataStore Preferences: a Long a JSON number would round (2^53 and beyond) is shown read-only and not written back rounded, a value outside an Int key's range is refused, and a string set keeps every row as typed, so `1.0` is not saved as `1` and a quoted `"x"` is not mistaken for `x` |

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
