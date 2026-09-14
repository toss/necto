# Installing the Necto app

Install a published app or build it from source, then connect an SDK-enabled app.

To inspect your app, first [integrate the Necto SDK](setup.md).
You can also use the bundled example app, which already includes the SDK.

## Published app

Download `Necto-<version>.dmg` from the
[release page](https://github.com/toss/necto/releases), open the image,
and drag Necto into Applications. For a manual integrity check, compare
`shasum -a 256 Necto-<version>.dmg` with the SHA-256 digest GitHub displays for
that asset. The checksum detects a mismatched download; it does not authenticate
the publisher.

The app and its embedded CLI use ad-hoc signing, without a company Developer ID
certificate or Apple notarization. Download only from the repository's release page.
Necto does not change system security settings to bypass Gatekeeper.

App updates use anonymous HTTPS, without `gh` or a GitHub login. Necto reads the
version tag from the `/releases/latest` redirect without calling the GitHub API.
Before replacing the app, it checks the DMG against the same release's `.sha256`
file, the new app's signature integrity, its bundle ID and a newer version.
Ad-hoc builds support these updates. These checks detect
corruption and incompatible apps, not a malicious release published through a
compromised repository account; the release repository is the trust source.

## Source build requirements

- macOS 14 or later, with an Xcode toolchain that provides Swift 6.0 or later.
- Node.js 22.12.0 or later and Yarn 4.6.0 to run `script/build`.

## Build and launch

```bash
git clone https://github.com/toss/necto.git
cd necto
corepack enable
script/build   # web packages, Swift packages, then the app
open Build/Products/Debug/Necto.app
```

You can also open `Necto.xcodeproj` and run the `Necto` scheme — built plugin
output is committed, so building the app alone does not require Node.

## Connect an app

**Your own app**, with the SDK wired per [setup.md](setup.md) — launch it in a
simulator or attach the device over USB. The app appears in Necto's sidebar when connected.

**No app yet** — run the bundled example app in a simulator.

```bash
xcrun simctl list devices available          # pick a device id
xcrun simctl boot <device-id>
xcodebuild -project Necto.xcodeproj -scheme ExampleApp -derivedDataPath Build -destination "id=<device-id>" build
xcrun simctl install <device-id> Build/Products/Debug-iphonesimulator/ExampleApp.app
xcrun simctl launch <device-id> im.toss.necto.example
```

## Watch the first request

Select the app in the sidebar and open the **Network** panel. Requests appear
the moment they start and fill in when they finish — method, status, size and
time, newest first.

The example app's **Plugin Sample** panel demonstrates bridge calls and
responses to rejected requests.

## If nothing appears

- For a simulator app, check the default SDK port range on the Mac with
  `lsof -nP -iTCP:9979-9986 -sTCP:LISTEN`. If you changed the base port, check that range instead.
- For a USB device, this Mac command cannot show the app's listening socket.
  Check that Xcode recognizes the device and that the app is running with the SDK started.
  When installing a development build, complete any device trust or Developer Mode
  prompts shown by Xcode or iOS. Configure Signing & Capabilities in Xcode if the app
  cannot be installed or launched; these failures occur before an SDK connection.
- On a device, a `connectionRefused` result means the tunnel reached the
  device but nothing was listening — the expected answer when the app is not
  running.
- [verification.md](verification.md) covers the full checklist.

## Where next

- Build a panel — [Part 1 of the tutorial](tutorial-desktop.md) makes a
  desktop plugin with nothing but a folder of web files.
