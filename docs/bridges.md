# Bridge catalog

What a plugin can ask Necto to do. A plugin calls its own operation id; the runtime
resolves that to one of these.

## Contents

- How a bridge is named
- Host bridges
- App bridges
- What Necto does not offer

## How a bridge is named

Operation IDs and bridge names serve different roles:

| | Example | Chosen by |
| --- | --- | --- |
| Operation id | `records.list` | The plugin |
| Bridge name and version | `necto.device.network-records.list` v1 | Necto |

The plugin's JavaScript only ever names the operation id. The manifest binds that id
to a bridge.

```json
"binding": {
  "name": "necto.desktop.storage.get",
  "version": 1
}
```

Bindings define the permissions a plugin requests; there are no separate permission
names. Desktop plugins list these bridges in the install dialog. For device plugins,
adding the package to the app grants access.

Two versions of a name are two different bridges. A provider must agree with the
manifest on name, version and kind, never on the name alone. Payload validation uses
the manifest's input and output schemas, not equality with the provider's schemas.
The kinds are `once` (one result) and `stream` (events until completion or cancellation).

For `once`, the registry returns a timeout or caller cancellation without waiting
for a provider that ignores cancellation. It still owns that provider task until it
exits and rejects retries on the same principal, binding and target with
`operationUnavailable` while it is stopping. A late result is discarded. Cancellation
requests cleanup; it does not guarantee rollback of effects already started.

## Host bridges

Provided by the Mac app. Available whether or not an app is connected, except where
noted.

These exist because they are the *host's* to answer — what Necto itself knows, keeps or
can reach. Anything belonging to the app under test is an app bridge, including
the ones Necto ships: `DefaultNetworkPlugin` declares its own contracts and answers them
from the app's own records, and nothing here knows it by name.

### Storage — `necto.desktop.storage.*`

Isolated by plugin principal, and by selected target when there is one. No other
plugin can read it, and the same plugin pointed at two apps keeps them apart. A plugin
installed from a different source is a different principal even under the same id.

This isolation applies to `necto.desktop.storage.*`. WebView cookies, local storage
and caches do not have the same per-principal isolation.

| Key | Kind | Input | Output |
| --- | --- | --- | --- |
| `necto.desktop.storage.get` | once | `key`, `scope?` | `found`, `value` |
| `necto.desktop.storage.set` | once | `key`, `value`, `scope?` | `success` |
| `necto.desktop.storage.remove` | once | `key`, `scope?` | `success` |
| `necto.desktop.storage.keys` | once | `prefix?`, `scope?` | `keys` |

`found` is separate from `value`: a stored `null` and a missing key are different
answers.

### Plugin-wide storage

Storage calls optionally accept `scope: "plugin"`. This uses a stable namespace for
the plugin principal, independent of selected devices and app restarts. The default
`scope: "target"` preserves existing behavior. Neither scope is a credential store.

### Background lifetime and notifications

All four bridges use version 1 and `once`. Declare their full binding names and
input/output schemas in the plugin manifest, then call the plugin's operation ID
through `necto.desktop.send(...)`.

| Key | Input | Output |
| --- | --- | --- |
| `necto.desktop.background.keepAlive` | — | `active` |
| `necto.desktop.notifications.requestAuthorization` | — | `granted` |
| `necto.desktop.notifications.status` | — | `granted` |
| `necto.desktop.notifications.show` | `id`, `title`, `body` | `submitted` |

Declaring `necto.desktop.background.keepAlive` opts an enabled desktop panel into an
app-owned lifetime independent of selection. Its `once` call returns `active: true`.
The host loads these approved panels at startup, keeps them mounted while another
panel or Settings is visible, and tears them down on disable/removal/content replacement.
Their target is nil, so selecting an iOS device does not restart the background account
panel. Ordinary panels retain their existing teardown behavior. System sleep/App Nap
and WebKit throttling can delay work; this is not an OS background service. Closing
Necto's last window or quitting stops everything.

If a web content process terminates, Necto reloads its document even while hidden.
Recovery waits 1, 2 and 4 seconds for up to three consecutive attempts; a minute
without another termination resets the budget. Further termination stops recovery
and writes a system log entry. Disable and enable the plugin to retry. Navigation
and teardown cancel pending recovery, so removed plugins cannot reopen themselves.

`necto.desktop.notifications.requestAuthorization` requests system alert/sound access;
`status` returns current `granted` state. `show` takes bounded `id`, `title` and `body`
and returns `submitted: true` after the notification center accepts it. This does not
prove on-screen delivery: system settings and Focus can suppress alerts. Identifiers
are scoped to the plugin principal, and the host labels each notification with its
plugin ID. No permission prompt is launched by `show` itself.
`id` must contain 1–256 characters, `title` 1–160, and `body` at most 1,000.

User-activated HTTPS links without embedded credentials open in the system browser,
keeping the plugin panel loaded.

### Targets — `necto.desktop.targets.*`

| Key | Kind | Input | Output |
| --- | --- | --- | --- |
| `necto.desktop.targets.list` | once | `includeDiscovered?` | `targets` |
| `necto.desktop.targets.observe` | stream | `includeDiscovered?` | `targets` per change |

A target is described by `targetHandle`, `name`, `appName`, `appBundleID`,
`deviceType`, `isConnected` and, when known, `nectoVersion`. There is no device id in
that list. A plugin can only address targets through handles issued to it.
Handles are per principal
and last for the host session.

### Network records — `necto.device.network-records.*`

*An app bridge, not a host one.* `DefaultNetworkPlugin` keeps the records in the app and
answers these itself. Collection starts when the app reports records, independently
of whether the panel is open. A later connection can read the retained records;
`DefaultNetworkPlugin` keeps up to 2,000 and discards the oldest when full.

| Key | Kind | Input | Output |
| --- | --- | --- | --- |
| `necto.device.network-records.list` | once | `limit?` | `records` |
| `necto.device.network-records.detail` | once | `recordID` | `record` |
| `necto.device.network-records.observe` | stream | — | `record` per change |
| `necto.device.network-records.clear` | once | — | `cleared` |

`list` returns summaries without bodies. Use `detail` to retrieve headers, bodies
and a reproducible cURL command.


### Host info — `necto.desktop.info`

| Key | Kind | Output |
| --- | --- | --- |
| `necto.desktop.info` | once | `nectoVersion`, `protocolVersion` |
| `necto.desktop.ticks` | stream | `sequence`, `timestamp` |

<a id="shell-access"></a>

### Shell — `necto.desktop.shell.*`

Each caller starts in Protected mode. Users can change access in **Settings → Shell
Access**, or approve a plugin's authorization request in Necto's native dialog.
Installing a plugin grants access to these bridge contracts; it does not approve a
command. Execution follows a separate host-owned policy keyed by the plugin principal.

| Key | Kind | Input | Output |
| --- | --- | --- | --- |
| `necto.desktop.shell.execute` | once | `command`, optional `stdin` in v2 | `stdout`, `stderr`, `exitCode` |
| `necto.desktop.shell.authorization.request` | once | `access?`, `commands?`, `title?`, `message?` | `approved`, `approvedCommands` |

`execute` runs the exact string through `/bin/bash --noprofile --norc -c`. In Command
approval mode the string must exactly equal one entry approved for that principal.
Protected mode refuses every command; per-plugin Full access accepts every command for
that principal. The global Full Access switch temporarily accepts every caller without
rewriting their saved settings.

`authorization.request` uses a native Necto dialog when new approval is needed;
already permitted requests can return without a dialog. JavaScript cannot add an
approval itself. Necto owns the dialog title and shows the plugin ID and source.
A plugin's supplied title and message appear in a separate, labeled section. The
response contains the exact subset the user approved. The older `reason` input remains
accepted as a message for compatibility.

`access` defaults to `commandApproval`, which requires at least one exact command.
`fullAccess` requires no command list and presents a stronger warning; approving it
changes only that plugin principal to Full access. A plugin can ask, but it cannot
elevate itself without the native user decision.

`necto-cli shell run` uses a dedicated CLI principal configured in Settings. General
`necto-cli plugin invoke` calls use the selected plugin's principal, including its
shell grants when that plugin exposes a shell operation. The control socket trusts
the local OS user; it does not authenticate a CLI caller as a separate plugin owner.

Shell execution v2 accepts up to 512 UTF-8 bytes of `stdin`, passed separately from
the exact approved command. V1 remains registered for existing plugins. Both routes
share the same permissions and concurrency limiter. Input is preloaded into a pipe
before launch, then the write end is closed; the process reads EOF after consuming the
input. It never enters command approvals or process arguments.
Callers must not put credentials in the command itself, and must clear transient input
after use. A script controls its own stdout, so the bridge does not redact its output.

The built-in executor defaults to 30 seconds and 1 MiB of combined stdout/stderr.
The provider allows at most four concurrent executions, with two per principal.
Cancellation, timeout or output overflow terminates the `Foundation.Process` Bash
process, escalating to `SIGKILL` after one second if needed. This does not guarantee
termination of background descendants. Cancelling an authorization request removes
its queued or visible dialog; plugin disconnection or removal also cancels its requests.

Command approval is a policy gate, not a sandbox. An approved command can invoke other
programs or mutable scripts, and Full access deliberately treats the caller like a
local native app. Settings explains this limitation.

Approvals belong to a principal, not a content hash. Device updates keep permissions
for the same app bundle ID and plugin ID. A local folder/ZIP update keeps its
installation UUID and permissions only after the user confirms its source. Changed
local bytes stay unloaded until reviewed; removal followed by reinstallation gets a
new UUID. See [identity and trust](plugin-manifest.md#identity-and-trust).

`WebPackages/BuiltInPlugins/Plugins/shell-demo` is a ready-to-install desktop plugin that exercises
the whole flow without a connected app. Build it with
`yarn workspace @necto-plugin/shell-demo build`, then choose that folder from Necto's
Desktop Plugins settings.

## App bridges

Registered by a connected app through the SDK, and scoped to one
`(pluginID, deviceID, appBundleID)`. A call without a selected target is refused
before a provider is looked up.

An app declares them by registering handlers:

```swift
struct VariablesPlugin: NectoPluginable {
    let id = "com.example.variables"

    func register(_ necto: NectoHandler) {
        necto.handle("variables.list") { input in
            ["variables": …]
        }

        necto.handle("variables.observe") { _, out in
            for await change in changes { await out.send(change) }
        }
    }
}
```

Names are relative to `necto.device.`, which is also how a panel calls them:
`handle("variables.list")` here is `necto.device.send("variables.list")` there, and
`necto.device.variables.list` in the manifest.

A handler that returns a value answers once; a handler that takes an `out` streams
events. The runtime determines the kind from the closure signature, so the operation
name is declared only when registering the handler.

Handlers do not declare a separate read/write flag. A plugin author's declaration
alone cannot establish safety, so bridge names describe the action, as in
`events.clear`. Panels provide their own confirmation prompts for destructive actions.

The host sends `plugin.invoke` and waits for a matching `plugin.result`. If the app
disappears while a call is parked, that call fails rather than hanging.

A plugin can be added and taken away while the app is running:

```swift
NectoSDK.register(VariablesPlugin())
NectoSDK.unregister(id: "com.example.variables")
```

Both use `plugin.register`, which replaces the plugin's entire catalog. An empty
catalog removes the plugin; no separate removal message is needed.
Reconnecting resends each existing registration. To replace a plugin in
the SDK, unregister its ID before registering the new implementation; a duplicate
registration asserts in debug and is rejected in every build.

An app plugin sends stream events through the `NectoHandler.Out` of an active
subscription. `DefaultNetworkPlugin.report(_:)` stores records in the app and notifies
its `network-records.observe` subscribers. The panel subscribes through
`necto.device.subscribe("records.observe", ...)`; there is no public `bridge.emit`
API or feature-specific host channel adapter for these records.

## What Necto does not offer

The following are not provided by Necto bridge APIs:

- raw sockets, or a token for one
- loading downloaded native code as a plugin module (shell commands are governed separately above)
- absolute file paths, or another plugin's opaque handle
- a plugin id, storage namespace, device id or bundle id chosen by JavaScript

Bridge restrictions do not block every web API in the WebView. Currently,
`allowedOrigins` does not restrict `fetch`, XHR, WebSocket, beacon or page navigation.
Cookies, local storage and caches are not assigned separate data stores per plugin
principal either. Only install plugins you trust.

Add bridge capabilities through a descriptor, a typed payload and a scoped host port.
Do not expose them through ad-hoc JavaScript globals.
