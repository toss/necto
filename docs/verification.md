# Verification

## Contents

- What to run for which change
- Verifying a connection
- Verifying a plugin
- Verifying design changes
- Verifying release artifacts
- Verifying update handoff
- What cannot be verified here

Run the smallest check that actually exercises the change, then say what you ran and
what you did not.

The root `resolutions` select patched Vite and esbuild versions because VitePress
1.6 and tsup 8.5 still request older ranges. Recheck upstream ranges before removing
these overrides. Dependency updates must pass web tests, panel and documentation
builds, release packaging tests, and a fresh vulnerability scan.

## What to run for which change

| Change | Run |
| --- | --- |
| Types, runtime, transport logic | `script/test swift` |
| Device panel cache, plugin loading, Mac app unit tests | `script/test native` (isolated storage; no app launch) |
| `@necto/bridge`, plugin sources | `script/test web` |
| Release packaging | `script/test release` |
| Update installation and relaunch ordering | `swift test --package-path NectoMac --filter UpdateFinisherTests`, then a pinned-Dock update |
| Built panel entry points and assets | `node script/check-panel-assets.mjs` |
| Tokens, `NectoTheme`, `components.css` | `script/test native`, then open the gallery in both appearances |
| Anything that reaches the app | `script/build`, then launch it |
| The SDK's public API | `script/build` with a simulator booted, including ExampleApp's SDK integration |
| Connection lifecycle or CLI device operations | `script/test e2e` |
| Contract change | Update fixtures in the same commit |

`script/test` runs Swift and Vitest unit tests, native cache and WebView integration
tests, package/release contracts and panel asset checks. Check layouts and localized
copy in the plugin preview. Passing tests does not verify UI or transport changes;
those also need checks in the app or on a device.

The `NectoAppTests` scheme runs Swift Testing without launching the Mac app. App
sources under test belong to both targets. Tests use an in-memory approval store,
temporary cache directories and isolated WebKit data stores. Run it in Xcode or directly:

```bash
xcodebuild -project Necto.xcodeproj -scheme NectoAppTests -destination 'platform=macOS' test
```

## Verifying a connection

### Automated simulator E2E

Quit Necto, then run `script/test e2e`. It builds the real Mac app, CLI and ExampleApp
with separate test bundle IDs, selects an existing iPhone 17 Pro simulator, and runs the
`NectoE2ETests` Xcode scheme. No company signing certificate or extra test tool is needed.

The test discovers the device and its plugins through the CLI, checks `plugin help`,
writes and reads a unique UserDefaults value (`once`), and receives three performance
events as JSONL (`stream`). It then terminates ExampleApp during a live subscription,
checks that the CLI exits with an error and the target disappears, and relaunches
ExampleApp to repeat both operations without restarting Necto.

Both CI and local runs use `iPhone 17 Pro` on the newest available iOS runtime that
has one, regardless of boot state. If none exists, the test fails immediately.
It opens Simulator and waits for boot to finish before installing the test ExampleApp
(`im.toss.necto.e2e.example`). An installation left by an interrupted run is replaced;
each test writes its own values. The app and temporary Mac home are removed afterward.
The simulator is left booted; it is never erased or deleted, and other installed apps
are left intact.
Other Necto instances must be closed because hosts share the SDK's loopback ports.
Waits check observable state with deadlines, not fixed startup delays or performance
thresholds. Build logs, command output and the test result bundle are in `Build/E2E/Logs`.
E2E is opt-in locally and is not part of the default `script/test` run.

CI runs `Simulator Connection & CLI E2E` after the Mac and SDK jobs. The Mac job
uploads the app, CLI and test bundle; the SDK job uploads ExampleApp. E2E downloads
those artifacts from the same workflow run and uses `test-without-building`.
Archives preserve executable permissions and bundle symlinks. To rerun locally
without rebuilding, use `script/test-e2e run` after `script/test e2e`.

Failed E2E runs upload logs and test results. This covers the real GUI host, CLI and
SDK transport path, not WebView interaction, layouts or USB.

### Manual connection checks

Use a simulator for the loopback connection path.

```bash
xcrun simctl boot <device-id>
xcodebuild -project Necto.xcodeproj -scheme ExampleApp -destination "id=<device-id>" build
xcrun simctl install <device-id> Build/Products/Debug-iphonesimulator/ExampleApp.app
xcrun simctl launch <device-id> im.toss.necto.example
```

The app shows the listening port, and the Mac app lists it under the sidebar within a
couple of seconds. `lsof -nP -iTCP:9979-9986 -sTCP:LISTEN` checks the default SDK
port range when it does not appear. If you configured another base port, check that
range instead.

For concurrent connections, launch SDK-enabled apps on two booted simulators. The
SDK chooses a free port within the eight-port range and the Mac probes all eight.
Confirm that both targets appear in the sidebar and `necto-cli targets`, then switch
between them and call a device operation on each. If all eight ports are occupied,
another SDK instance cannot start listening in that range.

For a device, attach it over USB and confirm it appears. A `connectionRefused` result
means the tunnel reached the device but nothing was listening, which is the expected
answer when the app is not running.

## Verifying a plugin

For CLI lifecycle changes, click **Install CLI** in Settings → General → Command
line tool, approve the macOS authentication prompt, and check
`necto --help`, `necto install --help`, `necto delete --help`, and the `necto-cli`
aliases. Check that mixed `--local --remote` flags and URLs passed with `--local`
fail. Then check `necto install <repo>`, `necto install <folder> --local`,
and `necto delete <pluginID> --json` against fixture plugins. Confirm install/update
approval, cancel during transfer then immediately retry, and attempt a GUI update while
a CLI request is active. The update must remain available when admission is refused.
Deletion must move files to Trash, remove grants/registration, and stop a background
panel. An unknown ID or device plugin must fail without changing files.
Overlap Reload with CLI install/delete and repeat Reload: admission must be refused
while another catalog operation owns the gate, and deleted rows must not reappear.

`NectoProcessRunnerTests` checks output, standard input, cancellation and deadlines,
including pipes inherited by descendants. Release downloads and shell execution use
that same runner. A cancelled transfer must close both output readers before admitting
another installation, including when a credential helper still holds the write end.

For identity or installation changes, also check these with global Full Access off:

1. Import a desktop folder/ZIP and approve one harmless shell command. Update it
   with the same manifest ID: cancel first (old files and grants stay), then confirm
   (installation UUID and command approval stay; content hash changes).
2. Modify installed files outside Necto, then Reload. They must appear under Review
   required, not execute with existing permissions. Check both confirm and cancel.
3. Remove and reinstall the same ID: the installation UUID changes and the command
   is no longer approved. Duplicate folders and a wrong-ID targeted update are refused.
4. Update/reconnect a device plugin with the same app bundle ID and plugin ID:
   shell grants stay. Another app's same ID must not inherit them. The SDK rejects
   duplicate registration even with assertions disabled; unregister/register works.

For destructive lifecycle tests, use both a temporary `CFFIXED_USER_HOME` for plugin
files and a separate test app bundle identifier for UserDefaults. The environment
variable alone does not isolate the preferences domain. Create the temporary home
directory before launching the app; otherwise macOS can disable preference writes
for that process. Capture fresh Loupe reports
before and after actions; a successful build is not UI evidence.

Build the web packages first, then the app: plugin output ships inside the bundle, so
an app built before `yarn build` carries stale assets.

For a device plugin, reinstall and launch ExampleApp on the simulator being inspected.
Building against another booted simulator updates that product but not the app already
serving the panel.

Check the plugin in the app, not only in a browser. Two things only appear in the
real host: the bridge, and the theme the window imposes.

Toggle System Settings between light and dark with the plugin open. Tokens should
follow without a reload.

For background plugins, also verify in a built Necto:

1. Reopen the app and switch selected devices: plugin-wide preferences persist.
2. Use a fixture plugin to submit a notification while another panel and Settings are
   visible, and confirm background work continues across both selection changes.
3. Disable/remove/update the plugin: background work ends. Ordinary panels still cancel
   on selection changes. Closing the last window stops work.
4. Test notification permission denied, Focus suppression and app-foreground delivery.
5. User-activated HTTPS links open in the system browser and keep the plugin panel alive.
6. Open a second window with Command-N: background initialization occurs only once.
   Activate each window to move the same page, preserving its input. Disable it from
   either window and confirm it stops everywhere, including after that window closes.
7. Focus a plugin input, open Settings with Command-comma, and type. The hidden input
   must not change. Repeat with another panel and confirm its own inputs still work.
8. Close the first window, then install a fixture through the CLI. The remaining
   window must show the approval and complete both approval and cancellation.

Native storage coverage is in `NectoStorageProviderTests`. `NectoShellProviderTests`
checks shell v2 standard input separately from approved commands. Actual WebView
lifetime and on-screen notification delivery require manual verification.

`script/test native` also exercises browser-storage isolation in real WKWebViews:
different app principals stay separate, approved updates retain values, and local
reinstallation gets fresh storage. It checks main-document bridge access and iframe
refusal, then loads the built Plugin Sample and verifies that provider error HTML is
displayed as text rather than executed.

Registry tests hold a provider callback past its deadline and cancellation, verify
that callers return promptly, and ensure a retry cannot accumulate unfinished work.
They also verify that removing a plugin cancels its active subscriptions without
stopping subscriptions on another connected device, and that a subscription still
opening cannot outlive removal or caller cancellation.
`NectoWebViewRecoveryTests` (in `script/test native`) loads real
hidden WKWebViews and injects content-process termination delegate events. It checks
reload, the retry limit, and cancellation on teardown. It does not force memory
pressure or terminate the user's WebKit processes; actual OS-triggered recovery
and long-duration operation remain separate runtime checks.

## Verifying design changes

Open `docs/design/index.html` to preview the shipped stylesheets in both appearances
and at both text sizes. Check readability in addition to contrast ratios.

## Verifying release artifacts

### Releasing from GitHub Actions

After the `Check` workflow succeeds on `main`, open **Actions → Release → Run
workflow**, select `main`, and enter a version such as `0.1.0`. Manual runs require
repository write access. The workflow only runs in `toss/necto` from `main`.
Building has read-only repository access; only the publishing job receives
`contents: write` through `GITHUB_TOKEN`. No personal token is needed.

A new version uses the commit selected when the workflow was started. If its tag
already exists, the workflow rebuilds that exact commit, which must be an ancestor
of `main` with a successful main `Check` run. It never moves an existing tag.
Packaging uses the workflow's release script while testing and building the tagged
source, so releases from before this workflow was added can be completed.

The publishing job verifies the DMG checksum, creates the tag and a draft if needed,
uploads all four files, and compares their sizes and SHA-256 digests before
publishing. An existing published version is refused. Identical files in a draft
are reused; conflicting files stop the run for review. An upload failure leaves
the release unpublished. Use **Re-run failed jobs** to retry publishing with the
same build artifacts, retained for seven days.

### Local checks

`script/test release` runs the release script in temporary fixtures with build,
signing and publishing tools replaced. It checks the generated artifacts, release
attachments and dry-run isolation without building an app or contacting GitHub.
It also checks bundle-version agreement, ad-hoc signing order and that
failures stop before tagging or publishing.
The Actions publication tests use simulated GitHub responses and cover tag/draft
resumption, CI gating, asset verification and publication failures.
It does not verify a real DMG, signing or an installed app's update flow.

The npm tarballs include `LICENSE`. The DMG and the app's `Contents/Resources`
include `THIRD_PARTY_NOTICES.txt`, added before signing. `yarn docs:build` emits
the same filename with licenses for the website's bundled dependencies and font.
Missing dependency licenses fail the build. Inspect the notices in the actual
artifacts before publishing.

`swift test --package-path NectoMac --filter NectoAppReleaseTests` checks release metadata, redirect policy,
bundle/version matching and real ad-hoc signed app fixtures, including the embedded
CLI. Valid updates must pass; unsigned or modified candidates must fail. Verify the
full download/install flow separately on a Mac without `gh`, starting with a
downloaded DMG and updating to a newer release. Modified apps, mismatched bundle IDs
and wrong-version artifacts must not reach update handoff.
`NectoUpdateDownloadTests` exercises HTTP failures,
redirect refusal, streamed byte limits and cancellation against a loopback server;
it does not replace a real GitHub HTTPS/CDN download test.

Both release modes ad-hoc sign and verify the embedded CLI and app before creating
the DMG. No company certificate or notarization profile is required.
`--dry-run` builds the artifacts without tagging or publishing. These signatures
check integrity, not publisher identity; updates trust the fixed release repository.

The release argument sets `MARKETING_VERSION`; the script reads the built
`CFBundleShortVersionString` and refuses a mismatch. Host info and update comparisons
read this bundle value, not an independent source-code version.

Public CI uses GitHub-hosted runners. The Mac job ad-hoc signs its app and test
bundle; the SDK job builds ExampleApp without signing.
`Check` runs five jobs: `Mac Build & Tests`, `SDK Build & Tests`,
`Simulator Connection & CLI E2E`, `Web Plugins Build & Tests`, and `Documentation Build`.
Mac, SDK and E2E use Xcode 26.6 on `macos-26`; web and documentation builds use
`ubuntu-24.04`. The four non-E2E jobs use Node 22.12.0, and web and documentation
builds use Yarn 4.6.0.
Documentation deployment remains a separate manual workflow. GitHub Pages must be
configured to deploy from Actions.
Workflow files alone do not prove a successful run on those machines.

`script/release` attaches the DMG, its `.sha256` file and two developer-package tarballs.
The checksum uses `shasum -a 256` format with the DMG's filename, without a directory.
The updater reads the version tag from a `HEAD /releases/latest` redirect, then fetches
the checksum and DMG from that exact release. It does not call the GitHub API or use
`gh` credentials. After publishing, verify the redirect and both versioned asset URLs
without authentication. Missing or malformed checksums must fail; modified DMGs must
be rejected before mounting. Verify same-version and older releases are not offered.
Users moving from 0.4.x to the public 0.1.0 release must install it manually once;
automatic updates never downgrade. Already-published assets are not changed by this script.

## Verifying update handoff

`swift test --package-path NectoMac --filter UpdateFinisherTests` exercises the Swift handoff logic against
temporary app directories. Process state, launch and injected failures are test
doubles. It checks exit-before-install/open, unchanged bundle-root inode, replacement
of all Contents, rollback and bounded waiting without launching Necto.

After a release build, verify that the signed `necto-cli` is included in the app.
Pin a disposable test copy in the Dock and update it: the old PID must exit before
the new one starts, the original Dock item must remain in its position, and no
second icon may remain. This requires an actual macOS app run; the Swift tests do
not prove Dock behavior or resource embedding. No Dock preferences are rewritten.

Successful handoffs remove their `.necto-update-*` staging directory beside the app.
Failures retain `install.log` and any `PreviousContents` for recovery; never delete
that backup if restoring it failed.

## What cannot be verified here

- **USB in a simulator.** The simulator has no usbmuxd path; it uses loopback.
- **Appearance without runtime evidence.** Build and static-check results do not prove
  how the app looks. Use Loupe or an authorized capture path; report the gap if the
  required runtime access or screen recording permission is unavailable.
