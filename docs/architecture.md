# Architecture

## Contents

- Shape of the system
- Module boundaries
- Why there is no server process
- Why the app listens and the Mac connects
- Plugin identity
- Usage event delivery
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
       NectoPlugin → NectoRegistrar (in the iOS app)
```

A plugin calls an operation id from its own manifest. The runtime matches it against
provider descriptors by name, version and kind, validates input against the manifest,
and then invokes the provider. Shell providers also check the caller's shell policy.

App plugins register handlers through `NectoRegistrar`. The host sends `plugin.invoke`
and receives `plugin.result`, paired by request ID through `NectoDeviceBridgeClient`:

- `once` returns one result.
- `stream` returns events until completion or cancellation. For example,
  `NectoNetworkPlugin` stores records in the app and sends changes to active
  `network-records.observe` subscribers through `NectoRegistrar.Out`.

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
| `NectoNetworkPlugin` | Network records and panel | Automatic traffic capture |
| `NectoEventsPlugin` | Application events and panel | Automatic event capture |
| `NectoFilesPlugin` | File browsing and panel | Other plugins |
| `NectoPreferencesPlugin` | Preferences access and panel | Other plugins |
| `NectoPerformancePlugin` | Performance readings and panel | Automatic process sampling |
| `NectoUIControlPlugin` | UI inspection, interaction and iOS touch runtime | Other plugins |
| `NectoProcessMetricPlugin` | Optional CPU, memory, FPS and thread sampling | Starting unless the app registers it and a reader subscribes |
| `NectoURLSessionCapturePlugin` | One capture mechanism, for apps using `URLSession` | Capture that an app cannot disable |
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

## Usage event delivery

Usage events use a host-side dispatcher, separate from diagnostic logs and ordinary
operation execution. The WebView bridge supports delivering events to an installed
desktop exporter. App-level dispatcher injection and persistent settings are follow-up
integration work; this runtime layer alone does not start collection in the app.
Plugin-facing recording APIs, host instrumentation and HTTP delivery are also separate work.

```text
Host recording entry -> Registry.recordEvent -> EventDispatcher -> registered exporter
                                                    |
                                            EventCollectionPolicy

Host exporter runtime ---------------------> registerExporter
```

`NectoPluginRegistry.recordEvent` verifies the host-supplied caller principal and
uses the installed manifest for the plugin ID, version and device/desktop origin. It forwards only explicit
records. Normal `invoke` and `subscribe` calls do not emit usage events. The registry
never selects or registers the exporter.

`NectoEventDispatcher` enriches a record, checks `NectoEventCollectionPolicy`, and
hands it to the registered receiver. The host supplies the installation ID and Necto
version. Installation ID persistence and app-level dispatcher composition are separate
integration work. Without a registered exporter, events are not delivered.

The optional manifest field `type: "event-exporter"` lets the installation UI explain
collection before running any plugin code. Installation and collection consent are
one action, covering Necto activity and current and future plugins except excluded IDs.
A second exporter cannot be installed until the current one is removed. A folder
discovered on disk still requires the existing review and approval flow.

When an installed background page is supplied with a dispatcher, it can call
`necto.registerExporter({ onEvent })`. The WebView coordinator registers its receiver
directly with that dispatcher.
Cancellation or installation failure does not start that page or call registration. The dispatcher does not store approval records or
recheck approval. It rejects a second live receiver. The callback must accept each
event promptly and return;
the exporter owns any subsequent asynchronous work, batching and persistence. The
callback is not an HTTP request handler and must not perform blocking network IO.
The registration token prevents an old runtime's cleanup from disconnecting a newer
registration. Navigation and removal unregister the old document; a reloaded document
must register again. No events from the gap are replayed.

`necto.diagnostics.log(level, message, metadata?)` adds the exporter identity and
current time to the host's local Log view. These diagnostics never call the usage
event dispatcher. Do not include credentials or raw event payloads in diagnostics.

Policy changes and callback delivery are serialized by the dispatcher actor without
suspending between the policy check and handoff. The policy is a separate value type,
owned by the dispatcher, so callers apply changes through `updatePolicy` rather than
mutating shared state. Collection policy contains only excluded plugin IDs; there
is no global collection switch. A registered exporter receives allowed events.
Removing the exporter unregisters its receiver and ends its runtime. Excluding one
plugin does not revoke events already accepted by the exporter.

There is no dispatcher queue or replay. Records received without a receiver or from
an excluded plugin are dropped, not retained for later registration or inclusion. Exclusions match plugin IDs across apps and versions. A host event related to
a plugin, such as opening its panel, uses the related ID for the same policy check.

### Event envelope

Record input contains `eventName` and optional
`params` (a JSON object, empty when omitted). Nested objects, arrays and nulls are
accepted. Classification belongs to the plugin: it may use event names or fields
such as `params.kind` or `params.category`. There is no common `kind` field or enum.
No per-event manifest declaration is required. Empty names, unknown
common fields and non-JSON values are rejected; destination-specific
size limits belong to the exporter. Event names and parameters do not determine
host identity, permissions or routing.

An exported event includes:

- `eventId`: unique occurrence ID, retained by the exporter when retrying that event.
- `occurredAt`: milliseconds since the Unix epoch when the dispatcher accepts the
  record, not when a server receives it.
- `installationId`, `nectoVersion`: host-supplied metadata.
- `origin`: `necto`, `device` (app-carried plugin), or `desktop` (installed
  desktop plugin). Plugin origin comes from the registry installation record, not
  the presence of a selected target or plugin-supplied parameters.
- `pluginId`, `pluginVersion`: included for plugin records; omitted for host records.
- `relatedPluginId`: included for host activity associated with a particular plugin.
- `channel`: `ui` or `cli` when established by the host; omitted for background or
  other activity that cannot be attributed to either surface.
- `eventName`, `params`: the explicit record input. Properties stay inside
  `params` and cannot replace top-level metadata.

The host must derive caller identity and channel from its execution context rather
than accepting those values from plugin JavaScript. Native event types stay in
`NectoMacService`; no SDK wire type, new operation provider or manifest binding is
introduced by this service.

## Build layout

Libraries are managed as Swift packages, and app targets live in `Necto.xcodeproj`.

The root package exposes `NectoSDK` for the bridge and separate products for each plugin.
Capture products remain separate and are never dependencies of the core SDK. Apps import and register
the plugins they use. The local `NectoMac/Package.swift` builds Mac services, `necto-cli` and their
tests. It depends on the root product for shared types and transport; the SDK has no
dependency on the Mac package or ArgumentParser. Run `script/test swift` to test both
packages and the selective-product consumer fixture.

Panels are built by Yarn workspaces into the Swift packages that carry them —
`Sources/<PluginModule>/Panels/<id>` for the defaults, the example app's bundle
for the sample — and committed so that building the app alone needs no Node.
