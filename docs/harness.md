# Harness

Implementation rules and verification steps for changes to the SDK, wire protocol
and bridges.

## Contents

- System structure
- Rule 1: the SDK is a bridge
- Rule 2: Necto does not decide how an app works
- Rule 3: a plugin is dynamic, an app permission is not
- Rule 4: bindings are declared, never inferred
- Rule 5: USB is the connection
- Rule 6: a plugin must be openable without Necto
- Rule 7: one design system, checked where Necto owns the code
- Checks by change

<a id="the-shape-everything-hangs-off"></a>

## System structure

```text
Web plugin (manifest.json + JS)        dynamic, added like an Obsidian plugin
   │ necto.device.send("records.list")   operation id only, never a bridge key
   ▼
Mac host  ── runtime ──┬─ host bridge      storage, targets, shell
                       └─ app bridge ──┐   contracts a connected app registers
                                       ▼
                              USB ── NectoSDK ── NectoPluginable
                                                  the app's own permission
```

Three layers, three different lifetimes. Web plugins are installed and removed at
runtime. Host bridges ship with the Mac app. App permissions are compiled into the
connected app.

## Rule 1: the SDK is a bridge

`NectoSDK` handles message transport and routing. Feature implementations must live
in separate plugin modules.

| Belongs in `NectoSDK` | Does not |
| --- | --- |
| Listening, handshake, session | Feature implementations |
| `NectoPluginable`, `NectoHandler` | A `URLProtocol`, a view walker, a flag store |
| Routing by contract key | Implementing individual contracts |
| The five `plugin.*` message kinds | A sixth kind for a new feature |

A new permission adds an `NectoPluginable` implementation in its own module. It never adds a wire message
kind, and it never adds a line to `NectoSDKRuntime`.

**Check:** `NectoSDK` imports only `NectoModel` and `NectoTransport`, and no file under
`Sources/NectoSDK` names a feature.

```bash
script/check-sdk-generic.sh
```

## Rule 2: Necto does not decide how an app works

Necto cannot know how an app makes requests, lays out views or stores flags. It may use
`URLSession`, a socket library, gRPC, or an obfuscated implementation.

So Necto ships **an interface and, separately, an optional implementation**:

```swift
NectoDefaultPlugins       // the interface: network.report(record)
NectoURLSessionCapture    // one implementation, its own module, opt-in
```

Both modules ship in the `NectoSDK` product. An app with its own stack registers
the reporting plugin and calls `report(_:)` without enabling URLSession capture. Wiring the
implementation into the interface's module would force a guess on every app that
does not fit it.

**Check:** the interface module never imports the implementation module. A capture
mechanism is always a separate target.

## Rule 3: a plugin is dynamic, an app permission is not

"Plugin" means two things and they are not interchangeable.

| | Web plugin | App permission |
| --- | --- | --- |
| Is | `manifest.json` + JS | Swift compiled into the app |
| Added | at runtime | at build time |
| Declares | operations | contracts |
| Talks | `necto.device.send(...)` / `necto.desktop.send(...)` | `NectoPluginable` + `NectoHandler` |
| Granted | permissions the user approves | whatever the app already can do |

A web plugin calls its own operation id. It never sees a bridge key, a device id, a
storage namespace or a plugin id it chose itself.

## Rule 4: bindings are declared, never inferred

Every operation states its binding in the manifest, and the provider states the same
route in code. Name, version and kind must agree. The manifest is the single source
for payload schemas; the runtime validates input, output and stream events against
those schemas instead of requiring identical provider schemas. Shell execution has
an additional host-owned approval policy.

A provider that matches on name alone is a hole: an incompatible version or stream
kind could be invoked as though it were the declared operation.

**Check:** `script/test swift` covers route mismatches and manifest-side payload validation.

## Rule 5: USB is the connection

Necto uses USB through usbmuxd for devices and loopback for simulators.
Wi-Fi and Bonjour connections are not supported.

The socket roles are inverted from the protocol roles, because usbmuxd can only reach
a port the device already has open:

| Layer | Mac | App |
| --- | --- | --- |
| Socket | client, connects | server, listens |
| Protocol | host, asks | provider, answers |

**Check:** nothing imports `Network.framework` Bonjour APIs or `NetService`.

## Rule 6: a plugin must be openable without Necto

Plugin layouts must be testable without building the Mac app or connecting a device.
Use a mock host behind `import.meta.env.DEV` during plugin development:

```bash
yarn workspace @necto-plugin/network-logger dev
```

The mock answers on the same `webkit.messageHandlers.necto` channel the app uses,
exercising the web bridge client's message handling. It does not verify Mac providers
or real device connections. Use long URLs, failures, pending rows and truncated bodies
to check layouts against representative traffic.

**Check:** `node script/check-plugin-layout.mjs` renders the plugin and fails on
horizontal overflow, clipped headers and overlapping controls. Type checking alone
does not detect these layout problems.

## Rule 7: one design system

Web plugins use `WebPackages/Bridge/theme.css` and `WebPackages/Bridge/components.css`;
the native shell uses matching Swift tokens. Keeping these values aligned helps plugins
match the built-in UI. Hardcoded colours can make a plugin look different from the app.

Necto's own UI — `Necto/`, `WebPackages/Bridge/`, `WebPackages/BuiltInPlugins/src/` —
must follow `docs/design.md`. External plugins may use other styles;
the bridge does not reject plugins based on their appearance.

The gallery at `docs/design/index.html` imports the shipped stylesheets directly.
Use it to preview changes:

```bash
script/serve-design
```

A device plugin carries the web assets from the app that built it, so its token
defaults can be older than the Mac shell. The host reasserts the current appearance,
neutral ladder and surface token at the WebView boundary. This keeps a plugin that
uses Necto tokens aligned without pretending Necto can restyle arbitrary hardcoded CSS.

The static harness compares the Swift theme, the host override and every committed
panel build against `theme.css`:

```bash
node script/check-design-tokens.mjs
```

The gallery harness keeps its native-shell mock aligned with the Swift defaults and
the current desktop/device plugin split:

```bash
node script/check-design-gallery.mjs
```

The panel asset harness also checks that every committed panel has `index.html` and
that each local script and stylesheet it references exists and is non-empty:

```bash
node script/check-panel-assets.mjs
```

When changing design tokens, check the following:

- **Matching token values:** run `node script/check-design-tokens.mjs` to check that
  `NectoTheme.swift`, the WebView host and `theme.css` use matching values.
- **Text contrast:** calculate contrast for the actual text and background colours
  used in the background, sidebar, surface, hover and selected states.

## Checks by change

| Changed | Run |
| --- | --- |
| `NectoModel`, `NectoMacService` pure logic | `script/test swift` |
| Wire protocol | `script/test swift` plus a real connection, both directions |
| `NectoSDK` | `swift test`, then Rule 1's check |
| A bridge or provider | `script/test swift`, then call it from the web plugin |
| Mac UI, DI, host bridge | `xcodebuild -scheme Necto -destination 'platform=macOS' build` |
| SDK or ExampleApp runtime | build and run `ExampleApp` on a booted simulator |
| Web plugin | `yarn build`, `node script/check-panel-assets.mjs`, `node script/check-plugin-layout.mjs`, then load it in the app |
| Design tokens, `NectoTheme`, `components.css` | `node script/check-design-tokens.mjs`, then open the gallery in both appearances |

ExampleApp needs a booted simulator, and device names differ per machine, so never
hardcode one:

```bash
SIM_ID="$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/{print $2; exit}')"
xcodebuild -project Necto.xcodeproj -scheme ExampleApp -destination "id=$SIM_ID" build
```

## Evidence to keep

Wire protocol and bridge changes require verification through a real connection.
Record the results and any checks you could not run:

- the app connected over USB, not just the simulator
- the web plugin rendered data that started in the app
- a disconnect failed parked calls instead of hanging
- a reconnect worked without restarting either side
- the rendered plugin was checked for layout problems, including clipped columns
