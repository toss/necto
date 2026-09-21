# Architecture

## Contents

- Shape of the system
- Module boundaries
- Why there is no server process
- Why the app listens and the Mac connects
- Plugin identity
- Build layout

## Shape of the system

```text
Web panel / CLI
   │ operation id
   ▼
NectoPluginRegistry
   ├── desktop provider (Mac)
   └── device provider
         ↕ NectoDeviceBridgeClient / session
       usbmuxd (device) · loopback (simulator)
         ↕ NectoSDK
       NectoPluginable → NectoHandler (in the iOS app)
```

A plugin calls an operation id from its own manifest. The runtime matches it against
provider descriptors by name, version and kind, validates input against the manifest,
and then invokes the provider. Shell providers also check the caller's shell policy.

App plugins register handlers through `NectoHandler`. The host sends `plugin.invoke`
and receives `plugin.result`, paired by request ID through `NectoDeviceBridgeClient`:

- `once` returns one result.
- `stream` returns events until completion or cancellation. For example,
  `NectoNetworkPlugin` stores records in the app and sends changes to active
  `network-records.observe` subscribers through `NectoHandler.Out`.

Both use the same generic messages. Adding an app feature means adding a plugin's
handlers and manifest bindings, not a feature-specific host adapter or wire message.

## Module boundaries

| Module | Owns | Must not contain |
| --- | --- | --- |
| `NectoModel` | Manifest, operation, target and handshake types, schema validation | UI, networking or WebKit dependencies |
| `NectoTransport` | Async socket I/O, accept primitives, message framing and connection defaults | USB discovery, SDK listener policy or operation meaning |
| `NectoCLIService` | Control request, response and socket endpoint shared by the app and CLI | Command parsing or provider execution |
| `NectoMacService` | Operation routing, host providers, device connections and control server | UI or app-specific features |
| `NectoSDK` | App-side listening, plugin registration and message routing | Feature implementations, `URLProtocol` or domain types |
| `NectoDefaultPlugins` | The plugins Necto ships: network, events, performance | How an app captures traffic |
| `NectoProcessMetrics` | Optional CPU, memory, FPS and thread sampling | Starting unless the app registers it and a reader subscribes |
| `NectoURLSessionCapture` | One capture mechanism, for apps using `URLSession` | Capture that an app cannot disable |
| `Necto/` | Shell UI and the plugin host | Feature screens |
| `ExampleApp/` | Verifying connection and plugins on a device | Product features |

Web and CLI calls must both go through the `NectoMacService` registry before
reaching a provider.

Shell execution follows that rule too. `necto-cli shell run` invokes the installed
internal CLI manifest through the registry, and web plugins bind the same host provider
from their manifests. The provider sees a principal from the registry and applies the
same shell policy before a process is started.

## Why there is no server process

The Mac app manages connections and execution directly. Plugin calls stay in process
without an extra IPC round trip or a separate server to manage.

`necto-cli` requires the Mac app to be running. It connects to the app's Unix domain
socket at `~/Library/Application Support/Necto/necto.sock`, using length-prefixed
JSON messages. The control server forwards requests to the same registry as web
panels; it is not an HTTP service. See [the control socket](control-socket.md).

## Why the app listens and the Mac connects

usbmuxd can only reach a port the device already has open, so the socket roles are the
reverse of the protocol roles.

| Layer | Mac | App |
| --- | --- | --- |
| Socket | client, connects | server, listens |
| Protocol | host, runs the runtime and sends requests | provider, registers handlers and responds |

The app also speaks first: it sends the handshake hello because it is the side that
knows its own identity. The Mac assigns the device id, since an app cannot know a
stable one for itself.

A hello with a different protocol version is rejected. Necto does not negotiate
protocol versions.

## Plugin identity

`NectoApp` owns one `NectoAppModel`, including the registry, control server, installer,
enabled state and background pages. Each `ContentView` has a `NectoWindowState` for
selection and Settings, and its own find session. A background plugin has one retained
WebView; activating a window moves that page without loading another document.
Only one live window presents an install or shell approval. Closing that window
reassigns pending presentation to a remaining window. CLI installation fails promptly
if no window is available. Hidden pages relinquish their own keyboard focus.

`InstallCoordinator` owns install/delete/reload admission, download tasks, source choices,
approval, commit and completion. `NectoAppModel` forwards display state and supplies
catalog reload/removal callbacks. GUI updates are removed from the update list only
after the coordinator accepts them. Cancellation waits for owned IO cleanup before
the next request is admitted. Initial and manual catalog reloads use the same gate;
installation commit reloads the catalog while retaining its existing ownership.

Plugin authorization uses the host-issued principal. Device principals combine the
app bundle ID and plugin ID; local desktop principals combine an installation UUID
and plugin ID. Remote desktop principals combine the normalized repository source
and plugin ID. Host-owned local records keep the last approved content hash, separate
from permission identity. The installer commits approved snapshots, and WebViews
serve those snapshots rather than mutable local files. Registry calls from a panel
check its expected principal so an old page cannot call as a replacement installation.
See [the trust policy](plugin-manifest.md#identity-and-trust).

## Build layout

Libraries are managed as Swift packages, and app targets live in `Necto.xcodeproj`.

The root package exposes one product, `NectoSDK`, containing the SDK, shared modules
and built-in plugins. Modules remain separate; apps import and register the plugins
they use. The local `NectoMac/Package.swift` builds Mac services, `necto-cli` and their
tests. It depends on the root product for shared types and transport; the SDK has no
dependency on the Mac package or ArgumentParser. Run `script/test swift` to test both
packages and the single-product consumer fixture.

Panels are built by Yarn workspaces into the Swift packages that carry them —
`Sources/NectoDefaultPlugins/Panels/<id>` for the defaults, the example app's bundle
for the sample — and committed so that building the app alone needs no Node.
