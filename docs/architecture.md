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

## Installed packages and runtime roles

`NectoInstalledPackage` holds the shared manifest, verified web archive, content hash,
source and installation identity. Loading, approval, updates and removal operate on
this package data. The manifest format and stored installation records are unchanged.

After approval, the app separates feature plugins (`NectoInstalledPlugin`) from its
single event exporter (`NectoInstalledExporter`). Sidebar selection, panel ordering
and feature enablement only inspect the plugin list. Package-level operations such
as update discovery and shell caller identity include both roles. Exporter metadata,
removal and the existing file-update action remain available in its settings page.

`NectoBackgroundPanels` owns background feature pages and their window placement.
`NectoExporterRuntime` independently retains one hidden exporter document. Changing
or closing a feature panel does not recreate that document. Removing the exporter
ends only its document; changing content or installation identity replaces it.
Both owners use `NectoWebPage` and its common WebKit bridge. Only the exporter runtime
supplies the dispatcher and diagnostics dependencies for exporter callbacks.

The registry still handles shared operation calls and caller identity. Exporter
event reception remains a direct registration with `NectoEventDispatcher`.

## Usage event delivery

Usage events use a host-side dispatcher, separate from diagnostic logs and ordinary
operation execution. An installed desktop event exporter receives events through its hidden WebView.
Web plugins can record explicit events with `necto.log(eventName, params?)`.
App plugins record through `NectoRegistrar.logger` over the existing `plugin.event`
transport. Host instrumentation, invocation-channel propagation and HTTP delivery
are separate follow-up work.

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
version. The app creates a random installation ID on first initialization and stores
it with plugin-ID exclusions in UserDefaults. Removing or replacing an exporter
does not reset either value. Without a registered exporter, events are not delivered.

The optional manifest field `type: "event-exporter"` lets the installation UI explain
collection before running any plugin code. Installation and collection consent are
one action, covering Necto activity and current and future plugins except excluded IDs.
A second exporter cannot be installed until the current one is removed. A folder
discovered on disk still requires the existing review and approval flow.

After successful installation, the background page calls `necto.registerExporter({ onEvent })`.
The WebView coordinator registers its receiver directly with the dispatcher.
Cancellation or installation failure does not start that page or call registration. The dispatcher does not store approval records or
recheck approval. It rejects a second live receiver. The callback must accept each
event promptly and return;
the exporter owns any subsequent asynchronous work, batching and persistence. The
callback is not an HTTP request handler and must not perform blocking network IO.
The registration token prevents an old runtime's cleanup from disconnecting a newer
registration. Navigation and removal unregister the old document; a reloaded document
must register again. No events from the gap are replayed.

A dedicated Event Exporter page in native Settings shows installation information,
plugin-ID exclusions and exporter diagnostics. It reads only the exporter source
from the existing diagnostic log; copying from this page includes only that source.
Opening the page does not acknowledge unrelated failures. The general Log page
and shared retention policy remain unchanged.
The exporter has no selectable feature panel or enable/disable switch.
`necto.diagnostics.log(level, message, metadata?)` adds the exporter identity and
current time to the host's local diagnostic log. These diagnostics never call the usage
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

### Recording from a web plugin

`necto.log(eventName, params?)` returns immediately without waiting for export.
It sends the common input through the page's authenticated WebKit bridge to
`NectoPluginRegistry.recordEvent`. The host supplies the installed ID, version,
principal and target; the caller cannot set envelope metadata. Device-carried pages
retain their device origin even though their recording channel is web.

All WebView calls use `channel: "web"`, including timers and hidden background
pages. This identifies the calling path, not a user gesture or a visible impression.
Plugins decide the event name, parameters and when to record. No operation is
recorded automatically and no per-event manifest declaration is needed.

A missing exporter or an excluded plugin drops the record without buffering.
Invalid inputs and stale or missing installation identities are rejected by the
host. The web helper contains failures so an ignored logging call cannot interrupt
the original feature or leave an unhandled promise rejection. It warns locally
without printing event parameters; outside Necto it is a no-op. There is no delivery
receipt, retry or queue in this helper.

### Recording from an app plugin

`NectoRegistrar.logger` supplies a `NectoPluginLogger` bound to that registration's
plugin ID. Keep the logger for callbacks or use it inside an existing handler;
`log(eventName, params:)` returns immediately and never throws. No caller-supplied
plugin ID, exporter reference or destination is needed.

The SDK emits `NectoPluginEvent` with the existing `plugin.event` message kind,
routing channel `necto.usage`, and payload `{ eventName, params }`. This routing
channel is separate from the optional exported `channel` field (`web` or `cli`).
The event router passes the full envelope and connected target to the registry.
The registry requires registration by that exact target, derives device origin and
uses the same target's carried manifest version when available. A panel is optional;
unknown `pluginVersion` is omitted rather than inferred from another app or a desktop
installation. Panel-less registrations are also listed by ID in collection settings.

`plugin.register` adds an optional `isRegistered` flag. `true` permits an empty
registered plugin that only logs; `false` removes it. This describes app registration,
not collection consent. When absent, the previous nonempty-catalog-or-panel rule
still applies. Existing message kinds and `NectoPlugin` protocol members stay the same.

There is no SDK logging queue or replay. Calls without an accepted connection are
dropped, and an event cannot move to a replacement connection. Retained loggers
stop working after their registration is removed, including after the same ID is
registered again. Events emitted before the host receives registration may also be
dropped. The host's collection policy and exporter registration still decide delivery.

App handler invocations do not yet carry their web/CLI origin. App logs therefore
omit exported `channel` in this implementation, even when an existing handler was
called through those surfaces. No handler is automatically instrumented.

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
- `pluginId`: included for plugin records; omitted for host records.
- `pluginVersion`: included when the host has the plugin manifest; omitted for
  app plugins without an available manifest and for host records.
- `relatedPluginId`: included for host activity associated with a particular plugin.
- `channel`: `web` or `cli` when established by the host; omitted for activity
  outside those paths. WebView timers and hidden pages also use `web`.
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
