# Necto Agent Guide

A macOS debugging tool for iOS apps. The shell is Swift; every feature screen is a
web plugin. [README.md](README.md) covers the same project from a user's view.

Everything here is written in English: code, comments, documentation and commit
messages. Every Swift and TypeScript file starts with the copyright header used
throughout the repository.

## Commands

| Task | Command |
| --- | --- |
| Build everything | `script/build` |
| Unit tests | `script/test` (or `script/test swift`, `script/test web`) |
| Run the app | `open Build/Products/Debug/Necto.app` |

Panels must be built before the Swift packages, because their output rides inside
`NectoDefaultPlugins` (and the sample panel inside the example app). `script/build`
does that in order.

## Layout

```text
Sources/NectoModel        Manifest, operation and target types, schema validation
Sources/NectoTransport    Shared byte streams, message framing and connection defaults
NectoMac/Sources/NectoCLIService   The control socket contract shared by Necto.app and necto-cli
NectoMac/Sources/NectoMacService   Mac providers, routing, device connections and control server
Sources/NectoSDK          The SDK and listener embedded in a connected app
Necto/                    macOS shell, built by Necto.xcodeproj
ExampleApp/              iOS sample app, built by Necto.xcodeproj
WebPackages/BuiltInPlugins/          src/ is source, Plugins/ is the committed build output
WebPackages/Bridge/               @necto/bridge, the plugin facing web library
```

## Rules that are easy to get wrong

- **Feature screens are web plugins.** Do not add a SwiftUI screen for a new feature.
- **The SDK is a bridge.** No feature lives in `NectoSDK`, and no feature gets its own
  wire message. A plugin is an `NectoPluginable` in its own module, and the protocol
  is two members: an id and a chance to register handlers. Adding a plugin must
  never change that shape.
- **Two sides, named for who answers.** `desktop` bridges are answered by the Mac app,
  `device` bridges by the connected app — on a phone or a simulator, both are the
  device. A web plugin says which at the call site: `necto.desktop.send(…)` or
  `necto.device.send(…)`. Only `device` can fail because nothing is connected.
- **No plugin is a special case.** The ones Necto ships are ordinary adopters of
  `NectoPluginable`: they declare contracts and answer them, and nothing on the Mac
  side knows any of them by name. A plugin that needs desktop code written for it is
  a plugin designed wrongly.
- **Two kinds of plugin, named for where they live.** A *device plugin* rides in the
  app: the package holds the implementation and its panel, registering it is the
  whole adoption, and the panel appears on the Mac while the app is connected. A
  *desktop plugin* works without any app — pure web, or `necto.desktop.*` only — and
  installs in Necto itself; an install that binds `necto.device.*` is refused. The
  plugins folder is the developer override and shadows a carried id.
- **A contract is a schema, not a Swift type.** What travels is `NectoJSONValue`, and
  its shape is declared in the manifest and checked against it. A payload type shared
  between the app and the host means the two are versioned together, which is the thing
  the bridge exists to avoid.
- **Necto does not decide how an app works.** Ship an interface; ship any capture
  mechanism as a separate module the app chooses to link.
- **No separate server process.** The Mac app owns connections and execution.
- **No hard coded colours or font sizes.** Use the tokens, and add an example to
  `docs/design/` for any component you add.
- **The gallery and the app share `WebPackages/Bridge/*.css`.** Editing it moves both, so a
  difference between them is never fixed there — look in the plugin's own CSS or in
  Swift. Changing the shared file changes the design itself.
- **Read the mock before changing how something looks**, and read every place the
  component appears in `docs/design/gallery.js`. The same class is styled
  differently in different panes on purpose.
- **Measure before proposing a value.** Computed styles from `script/serve-design`,
  pixels from a screenshot of the app.
- **Plugins never receive** an API base URL, a token or a raw device id. Targets are
  addressed through the host issued `targetHandle`.
- **The lockfile must reference the public npm registry only.** Configure mirrors in a
  user level `~/.yarnrc.yml`.
- **The USB path cannot be verified in a simulator.** Use a device, and say so when you
  have not.
- **Only code that can be public.** Company specific features stay out, and nothing is
  copied from the internal Necto repository.

## Reference

Read the one that matches the change:

- **Rules a change must survive, and how to check them**: [docs/harness.md](docs/harness.md)
- **Architecture and module boundaries**: [docs/architecture.md](docs/architecture.md)
- **Plugin manifest and bridge contract**: [docs/plugin-manifest.md](docs/plugin-manifest.md)
- **What a plugin can ask Necto to do**: [docs/bridges.md](docs/bridges.md)
- **Design tokens, dark mode, accessibility**: [docs/design.md](docs/design.md)
- **How to verify a change**: [docs/verification.md](docs/verification.md)
