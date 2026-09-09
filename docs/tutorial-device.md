# Part 2 — Your first device plugin

In [Part 1](tutorial-desktop.md) the plugin ran entirely on the Mac; this one rides in
the app. A device plugin is one Swift package that carries both the implementation and
its web panel: the app links the package and registers the plugin, and the panel
appears in Necto while the app is connected. Nothing is installed on the Mac side —
[plugin-manifest.md](plugin-manifest.md) explains the two kinds.

We build **Uptime**: a panel that shows how long the app has been running. Two
operations, one of each kind —

- `uptime.get` answers once with when the app started and the seconds since.
- `uptime.observe` streams the seconds, once per second, while the panel watches.

You need a [running Necto and the example app](install.md), plus Node 22.12 or later for the
panel build.

## The package

Create the package next to your `toss-necto` checkout:

```bash
mkdir -p necto-uptime-plugin/Sources/NectoUptimePlugin
mkdir -p necto-uptime-plugin/panel/public necto-uptime-plugin/panel/src
cd necto-uptime-plugin
```

The package layout:

```text
necto-uptime-plugin/
  Package.swift
  Sources/NectoUptimePlugin/
    UptimePlugin.swift        the implementation
    Panel/                    the built panel — vite writes it here
  panel/                      the panel source
    index.html
    package.json
    vite.config.js
    public/manifest.json
    src/main.js
    src/style.css
```

`Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "necto-uptime-plugin",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(name: "NectoUptimePlugin", targets: ["NectoUptimePlugin"]),
    ],
    dependencies: [
        // The label after `package:` below is this folder's name — adjust both
        // if your checkout is called something else.
        .package(path: "../toss-necto"),
    ],
    targets: [
        .target(
            name: "NectoUptimePlugin",
            dependencies: [
                .product(name: "NectoSDK", package: "toss-necto"),
            ],
            resources: [
                .copy("Panel"),
            ]
        ),
    ]
)
```

`resources: [.copy("Panel")]` includes the built panel in the module's resources.
Rebuild and commit the panel assets when web sources change, then test them with
the native implementation distributed in the same package.

## The contract

The manifest is the contract. It declares the operations the panel may call, and the
runtime connects nothing that is not named here — no Swift type is shared with the
Mac. What travels is JSON, validated against these schemas at the runtime boundary
on the way in and the way out. See [plugin-manifest.md](plugin-manifest.md) for each
field's definition and whether it is required.

`panel/public/manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "uptime",
  "name": "Uptime",
  "description": "How long the app has been running",
  "version": "1.0.0",
  "author": "You",
  "icon": { "systemName": "clock" },
  "assets": ["index.html", "assets"],
  "allowedOrigins": ["self"],
  "operations": [
    {
      "id": "uptime.get",
      "title": "Read uptime",
      "description": "When the app started, and the seconds since",
      "kind": "once",
      "binding": {
        "name": "necto.device.uptime.get",
        "version": 1
      },
      "inputSchema": { "type": "object", "additionalProperties": false },
      "outputSchema": {
        "type": "object",
        "properties": {
          "startedAt": { "type": "string" },
          "uptimeSeconds": { "type": "number" }
        },
        "required": ["startedAt", "uptimeSeconds"],
        "additionalProperties": true
      },
      "timeoutMs": 3000
    },
    {
      "id": "uptime.observe",
      "title": "Observe uptime",
      "description": "The seconds since launch, once per second",
      "kind": "stream",
      "binding": {
        "name": "necto.device.uptime.observe",
        "version": 1
      },
      "inputSchema": { "type": "object", "additionalProperties": false },
      "outputSchema": {
        "type": "object",
        "properties": {
          "uptimeSeconds": { "type": "number" }
        },
        "required": ["uptimeSeconds"],
        "additionalProperties": true
      },
      "timeoutMs": 0
    }
  ]
}
```

The manifest `id` must match the Swift plugin's ID to associate the panel with its
provider. Each `binding` names a `necto.device.` bridge answered by the app.
These bindings are refused during desktop installation.

The output schemas leave `additionalProperties` open on purpose, so adding a field
later is not a breaking change — [plugin-manifest.md](plugin-manifest.md#when-a-bridge-version-moves)
covers when `binding.version` moves.

## Answering on the device

[`NectoPluginable`](https://github.com/toss/toss-necto/blob/main/Sources/NectoSDK/NectoPluginable.swift)
requires you to implement `id` and `register(_:)`. Its `panel` property defaults to
`nil`; plugins with a panel override it to point to the `Panel` directory in the
module's resources.

`Sources/NectoUptimePlugin/UptimePlugin.swift`:

```swift
import Foundation
import NectoModel
import NectoSDK

/// How long the app has been running, asked once or watched live.
public struct UptimePlugin: NectoPluginable {
    public let id = "uptime"

    private let startedAt = Date()

    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module) }

    public init() {}

    public func register(_ necto: NectoHandler) {
        necto.handle("uptime.get") { _ in
            [
                "startedAt": .string(ISO8601DateFormatter().string(from: startedAt)),
                "uptimeSeconds": .number(Date().timeIntervalSince(startedAt)),
            ]
        }

        necto.handle("uptime.observe") { _, out in
            while !Task.isCancelled {
                await out.send(["uptimeSeconds": .number(Date().timeIntervalSince(startedAt))])
                try await Task.sleep(for: .seconds(1))
            }
        }
    }
}
```

Handler names are relative to `necto.device.` — `handle("uptime.get")` here is the
`necto.device.uptime.get` the manifest binds, and `necto.device.send("uptime.get")`
in the panel. The closure shape picks the kind: return a value and the operation
answers once; take an `out` and it streams until the closure returns or the caller
stops listening, which cancels the closure's task and ends the loop.
See [bridges.md](bridges.md#app-bridges) for handler registration details.

Payloads use `NectoJSONValue` and are validated against the manifest schema.
Sharing a payload struct would couple the app and host versions.

## The panel

The panel is a web page that calls operations by their manifest ids. This example
bundles `@necto/bridge` with vite so it can run without downloading external files.

`panel/package.json`:

```json
{
  "name": "uptime-panel",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "@necto/bridge": "https://github.com/toss/toss-necto/releases/download/0.4.0/necto-bridge-0.4.0.tgz"
  },
  "devDependencies": {
    "vite": "^6.0.0"
  }
}
```

`panel/vite.config.js` — output goes straight into the Swift package's resources, and
`public/manifest.json` is copied alongside it:

```js
import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "../Sources/NectoUptimePlugin/Panel",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name].[ext]",
      },
    },
  },
});
```

`panel/index.html`:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="color-scheme" content="light dark" />
    <title>Uptime</title>
    <link rel="stylesheet" href="./src/style.css" />
  </head>
  <body>
    <div class="necto-app">
      <div class="necto-body">
        <h2 class="necto-section-title">Uptime</h2>
        <div class="necto-toolbar-group">
          <button type="button" class="necto-button" id="refresh">Refresh</button>
        </div>
        <dl class="necto-pairs">
          <div><dt>Started at</dt><dd id="started-at">—</dd></div>
          <div><dt>Uptime</dt><dd id="uptime">Loading…</dd></div>
        </dl>
      </div>
    </div>
    <script type="module" src="./src/main.js"></script>
  </body>
</html>
```

`panel/src/style.css` — the two shared stylesheets, and nothing hardcoded. Tokens are
how the panel follows the window into dark mode with no theme code of its own; the
rules and the full list are in [design.md](design.md):

```css
@import "@necto/bridge/theme.css";
@import "@necto/bridge/components.css";

.necto-body {
  padding: var(--necto-space-3);
}
```

`panel/src/main.js` — `necto.device.send` for the query, `necto.device.subscribe` for
the stream. The side is named at the call site because only `device` can fail from
nothing being connected:

```js
import { necto, isNectoBridgeError } from "@necto/bridge";

function show(id, text) {
  document.getElementById(id).textContent = text;
}

function describe(error) {
  return isNectoBridgeError(error) ? `${error.code}: ${error.message}` : String(error);
}

async function refresh() {
  try {
    const snapshot = await necto.device.send("uptime.get");
    show("started-at", snapshot.startedAt);
    show("uptime", `${Math.round(snapshot.uptimeSeconds)} s`);
  } catch (error) {
    show("uptime", describe(error));
  }
}

async function main() {
  if (!necto.isAvailable()) {
    show("uptime", "This plugin only works inside Necto");
    return;
  }

  document.getElementById("refresh").addEventListener("click", () => void refresh());

  await refresh();

  try {
    await necto.device.subscribe(
      "uptime.observe",
      {},
      (event) => show("uptime", `${Math.round(event.uptimeSeconds)} s`),
      (error) => show("uptime", describe(error)),
    );
  } catch (error) {
    show("uptime", describe(error));
  }

  // Signal only after every handler is registered; the host buffers events until then.
  await necto.ready();
}

void main();
```

Build it:

```bash
cd panel
npm install
npm run build
cd ..
```

`Sources/NectoUptimePlugin/Panel/` now holds `manifest.json`, `index.html` and
`assets/`. The panel always builds before the app — the SDK reads the `Panel` folder
at registration, so an app built first carries stale assets, or none.

## Carry it in the app

Adding the package to the app grants access to the device plugin.
There is no separate installation dialog on the Mac.

1. Open `Necto.xcodeproj` in the `toss-necto` checkout.
2. File ▸ Add Package Dependencies… ▸ Add Local…, and pick `necto-uptime-plugin`.
3. In the `ExampleApp` target, under General ▸ Frameworks, Libraries, and Embedded
   Content, add `NectoUptimePlugin`.

Then register it in `ExampleApp/ExampleApp.swift`, anywhere before `NectoSDK.start()`:

```swift
import NectoUptimePlugin
```

```swift
NectoSDK.register(UptimePlugin())
```

Run it, on the simulator loop from [verification.md](verification.md):

```bash
xcrun simctl list devices available          # pick a device id
xcrun simctl boot <device-id>
xcodebuild -project Necto.xcodeproj -scheme ExampleApp -destination "id=<device-id>" build
xcrun simctl install <device-id> Build/Products/Debug-iphonesimulator/ExampleApp.app
xcrun simctl launch <device-id> im.toss.necto.example
```

With Necto running (`open Build/Products/Debug/Necto.app`), the app appears in the
sidebar within a couple of seconds, and **Uptime** with it. Open the panel: the
seconds tick up once per second, and Refresh re-asks the query. Necto fetched the
panel from the app over the wire — nothing was installed on the Mac, and the panel
stays for as long as the app offers it, going gray when the app disconnects.

<a id="verify-like-a-contributor"></a>

## Verify the plugin

The checks from [verification.md](verification.md) that apply here:

- **Order matters.** Panel first (`npm run build`), then the app — plugin output rides
  inside the package, so an app built before the panel carries stale assets. And
  reinstall the app on the simulator being inspected: building against another booted
  simulator updates that product, not the app already serving the panel.
- **Check it in the app, not only in a browser.** Two things only appear in the real
  host: the bridge, and the theme the window imposes. `npm run dev` gives the layout
  loop — the page renders its fallback line, since the bridge is not there.
- **Toggle System Settings between light and dark** with the panel open. Because the
  panel draws from the tokens, it follows without a reload.
- **Break the contract on purpose.** Return `.string` where the schema says number and
  the call fails with `INVALID_OUTPUT` before it reaches the panel.
- **The USB path cannot be verified in a simulator.** The simulator uses loopback.
  Before trusting the plugin on a device, run it there over USB, and say so when you
  have not.

When contributing a plugin or changing a bridge, follow the implementation rules
and verification steps in [harness.md](harness.md).

## Where next

- [plugin-manifest.md](plugin-manifest.md) — the full manifest reference: version
  axes, error codes, and what each plugin kind can do.
- [bridges.md](bridges.md) — everything a panel can ask Necto to do, including the
  desktop bridges.
- [harness.md](harness.md) — implementation rules and mock-host verification.
- [setup.md](setup.md) — wiring plugins into your own app and excluding SDK calls
  from Release builds.
- [CONTRIBUTING.md](https://github.com/toss/toss-necto/blob/main/CONTRIBUTING.md) — how to contribute your plugin.
