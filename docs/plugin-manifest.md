# Plugin Manifest v1

A plugin is a `manifest.json` and a set of web assets. It contains no native code.

The manifest is the contract: it declares what the plugin may do. Anything not
declared here is not connected by the runtime.

## Three version axes

These versions describe separate contracts.

| Field | Question it answers | Example |
| --- | --- | --- |
| `schemaVersion` | Can a parser read this file? | `1` |
| `version` | Which release of the plugin is this? | `"1.0.0"` |
| `binding.version` | Which shape of this one bridge? | `1` |

The manifest declares required bridges and their versions, not a minimum Necto
version. The host reports unavailable bindings individually.

### When a bridge version moves

Increment `binding.version` for a breaking contract change, not for every release.

- Adding a field to what a bridge returns: **no bump.** A reader written against the
  old shape still parses the new one. Output schemas are open (`additionalProperties`
  is not `false`) precisely so this stays true.
- Adding an optional input with a default: **no bump.** An old caller that omits it
  still works.
- Removing or renaming a field that was required, changing a type, or changing what a
  value means: **bump.** An old reader cannot make sense of it.

A version that does not match is refused rather than negotiated. There is no range
syntax and nothing falls back.

## Fields

| Field | Required | Type | Description |
| --- | --- | --- | --- |
| `schemaVersion` | ✅ | `1` | Manifest format version |
| `type` | — | `"event-exporter"` | Identifies an event exporter; omit for an ordinary plugin |
| `id` | ✅ | string | Unique identifier, `[A-Za-z0-9._-]+` |
| `name` | ✅ | string | Name shown in the sidebar |
| `description` | ✅ | string | One line summary |
| `version` | ✅ | string | Plugin version (semver) |
| `author` | ✅ | string | Author display name |
| `authorUrl` | — | string | Author link |
| `icon` | ✅ | object | `{ "systemName": "network" }`, an SF Symbols name |
| `assets` | ✅ | string[] | Files and directories to package |
| `allowedOrigins` | ✅ | string[] | Origin declarations: `self` or `https://…`. Currently only the value format is validated |
| `operations` | ✅ | object[] | Operations the plugin may call; empty for a pure web tool |

`allowedOrigins` is not a network allowlist. Independently of that declaration,
the host restricts top-level navigation to the installed panel's origin and accepts
native bridge messages only from that top-level document. HTTP(S) links activated
in that document open in the browser. External frames can load web content but
cannot call the native bridge; ordinary web network requests are not blocked.

There is no `permissions` field. The bridges bound by a plugin's operations define
its requested permissions.

`type` is optional. Existing manifests without it remain ordinary plugins. The only
supported value is `"event-exporter"`; other values are rejected. Event exporters
install as desktop plugins and cannot bind `necto.device.*` operations. A page
carried by a connected app cannot register an exporter receiver. The marker does
not itself grant access to events.

For a desktop plugin, installation approval covers the requested bridges: the dialog
lists every bridge, and declining leaves the plugin uninstalled. Local updates require
source confirmation again. Device plugins trust the app developer who registers them.
Every call still validates its route and payload; shell execution also checks its
separate runtime policy.

Device plugins cannot call `necto.desktop.shell.*`, including authorization requests.
The host returns `PERMISSION_DENIED` even with saved shell grants or Global Full
Access. Existing panels still load; their device and other desktop operations keep
their existing behavior.

A plugin reaches Necto one of two ways, and the way is decided by what it binds:

- **Device plugins.** Anything that binds `necto.device.*` ships inside the Swift
  package that implements it, as a `Panel` resource next to the code. The app links
  the package and registers the plugin; Necto fetches the panel over the wire when the
  app connects and shows it for as long as the app offers it. The panel and its
  implementation are distributed together. Rebuild committed web assets when their
  source changes and verify them against the registered contracts.
- **Desktop plugins.** What works without an app — pure web tools, plugins that
  bind only `necto.desktop.*` — installs in Necto from a folder or a zip. A desktop
  install that binds `necto.device.*` is refused: the plugin that needs the app rides
  in the app.

The plugins folder also supports development overrides. An approved folder takes
precedence over a panel with the same id from a connected app, allowing panel changes
without rebuilding the app.

### Shell commands available for approval review

Shell permissions are described by existing operations. There is no separate
`shellAccess` field. A `necto.desktop.shell.execute` binding requests execution;
the operation's `description` explains its purpose. When its
`inputSchema.properties.command.enum` lists exact commands, the host can read and
review those commands before running any plugin code.

For example, the relevant fields of an exporter manifest could be:

```json
{
  "type": "event-exporter",
  "operations": [
    {
      "id": "environment.read",
      "title": "Read environment",
      "description": "Attach the operating system name to exported events.",
      "kind": "once",
      "binding": { "name": "necto.desktop.shell.execute", "version": 1 },
      "inputSchema": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "enum": ["uname -s"] }
        },
        "required": ["command"]
      },
      "outputSchema": { "type": "object" },
      "timeoutMs": 30000
    }
  ]
}
```

A command enum is optional for both ordinary plugins and exporters. An operation
with `"command": { "type": "string" }` remains valid; it just does not supply an
exact list for approval before execution. When present, the enum already limits
operation inputs through normal schema validation, even under Full Access.
Neither the enum nor its description grants execution permission.

`NectoShellOperationInterpreter.interpret(operations:)` performs installation-time
interpretation without plugin execution or permission state. The interpreter and
actual providers use `NectoShellContracts` for shell execution v1/v2 and authorization
v1 descriptors. They do not keep separate supported-version lists. Matching uses
`NectoBridgeDescriptor.mismatch(with:)`, the same name/version/kind comparison the
registry uses at runtime. The execution contract also owns the command field name.

The interpreter asks `NectoJSONSchema.declaredStringValues(for:in:)` for that
property's directly declared string enum. This general query preserves strings,
order and empty arrays. It distinguishes missing properties, absent enums,
non-string enumerations and unsupported schema shapes; it knows nothing about
shell permissions. It does not resolve references, combine schemas or replace
normal input validation.

Every operation naming a known shell bridge remains in the interpretation result,
with its ID, description, binding and kind. A supported execution carries either
its declared candidates or the lookup's unavailable reason. Authorization requests
are identified separately. Unsupported versions and kinds remain explicitly
unsupported instead of being interpreted with the current execution schema.
The interpreter does not trim commands, parse Bash, query grants or approve a subset.

`NectoShellPolicy.review(interpretedOperations:for:)` consumes these typed results;
it does not read manifest JSON keys. It reports whether complete declared-command
approval can be offered, the exact installation principal's saved grant (if any),
and the global Full Access override. Command approval requires at least one
supported execution, nonblank descriptions, nonempty candidate lists and commands
accepted by the existing shell command check. Any incomplete or unsupported shell
operation prevents that choice, while all interpretation results remain available
for explanation. Missing declarations do not invalidate the manifest.

A new candidate without a verified existing principal does not inherit a saved
grant by plugin ID. Review does not change grants. The effective access level uses
the global override, then the saved level, defaulting to Protected. Registry lookup,
runtime schema validation and invocation routing remain unchanged.

Write descriptions in English for publicly distributed exporters; each description
is displayed as authored and other languages are allowed. It is an author-provided
explanation, not a host-verified claim about the command's effects.

The installation sheet offers Full Access, declared Command approval when available,
Protected, or rejection. A shell access choice must be selected explicitly before
confirming. If global Full Access is already enabled, or no shell operation is
requested, only collection approval or rejection is needed. In those cases the
existing individual shell grant is preserved; a new installation gets no extra
shell grant from approval.

AccessController applies and persists the choice before the Exporter is loaded.
Command approval replaces the previous command list with the declared commands;
Full Access and Protected clear the old list. Installer rechecks the reviewed
policy and installation before approving. A failed load restores the shell grant
changed by that approval unless a later policy change has replaced it. This does
not roll back installed files. Ordinary plugin installation retains its existing
shell approval flow. The [exporter CLI commands](control-socket.md#exporter-approval-from-the-cli)
use the same installation and permission application without opening a sheet.
Ordinary CLI commands report pending exporters on stderr without blocking their
original operation. Explicit rejection remembers the reviewed ID and content hash
across app restarts; changed content is announced again. Closing the approval sheet
without selecting Reject does not remember a rejection.

### Identity and trust

`id` identifies the plugin; `name` labels its UI and may change independently.
Use a stable lowercase reverse-domain ID, for example `com.example.notes`. This is
a convention, not domain verification: `[A-Za-z0-9._-]+` remains the accepted format,
short IDs remain compatible, and UUIDs are not required in manifests. Changing an
ID creates a different plugin, not an update. Keep the Swift and manifest IDs equal.

| Source | Permission identity | Who establishes trust? |
| --- | --- | --- |
| Device | `appBundleID` + `pluginID` | The app developer who registers the plugin |
| GitHub Release | Normalized repository source + `pluginID` | The user approving that repository as the source |
| Local folder / ZIP | Host-created installation UUID + `pluginID` | The user confirming the files' source |
| `necto-cli shell` | Necto's dedicated CLI principal | Its own Shell Access entry in Settings |

Necto installs release assets from GitHub repositories, not arbitrary Git revisions.
It has no central plugin registry or plugin-signature system. A reverse-domain ID,
manifest `author`, ZIP filename or folder path
does not authenticate its publisher. Installation UUIDs live in Necto's records,
outside plugin payloads, and cannot be supplied or inherited through a ZIP.

**Device updates.** Same app bundle ID and plugin ID retain their principal when files
change. Different apps' same-named plugins have separate principals. The SDK asserts on
a currently registered duplicate ID in debug and rejects it in every build, before
calling its handlers. Intentional replacement uses `NectoSDK.unregister(id:)` then
`register`. Reuse of an ID by a different implementation inside a trusted app is
the app developer's responsibility; this is not publisher authentication.

Bridge name/version pairs must also be unique within the app. The SDK rejects
duplicate contracts, and the host refuses to route an ambiguous provider catalog.

**Repository updates.** The normalized host, owner and repository identify the
source; the release tag does not. Updates keep grants for the same source and plugin
ID. New bindings require approval. A different repository or replacement from local
files does not inherit the previous source's grants.

**Local updates.** In Settings → Desktop Plugins, use Choose… or right-click an
installed plugin → Update from file…. The latter requires the same manifest ID.
Confirm only if the folder/ZIP really is an update from a source you trust: that
decision preserves its installation UUID, bridge approvals and shell settings.
All requested bridges are displayed again, including new capabilities. Cancelling
or failing an import leaves the installed version unchanged; replacement keeps a
recoverable backup on failure. No match automatically inherits permissions.

`contentHash` records the last approved files and detects changes; it is not a
permission key. Necto serves an in-memory snapshot of checked assets. After Reload,
new or modified folders appear under Review required and do not load until approved.
Duplicate local IDs are rejected, not resolved by scan order. Removing in Necto
revokes grants and its installation record. Deleting a folder is recognized on the
next Reload or launch; reinstalling then receives a new UUID. Delete-and-replace
between scans cannot be distinguished from an update, so changed bytes still need
source confirmation. Necto does not defend against an attacker modifying its own
host records or process as the same OS user.

**Existing installations.** Older path-only local installations have no trustworthy
installation record. They need one source review to create a UUID and do not
automatically inherit old permissions or storage namespaces. Device and CLI
principals stay unchanged. Subsequent approved local updates keep their UUID.

Browser storage is scoped to the same plugin principal: app bundle ID and plugin ID
for device plugins, installation UUID and plugin ID for local desktop plugins, or
repository identity and plugin ID for repository installations. Updating the same
principal preserves browser storage; changing content alone does not reset it.
The old plugin-ID-only browser storage is not migrated because its owner is ambiguous.
Unregistered previews use temporary browser storage.

The length-prefixed content-hash format invalidates earlier content approvals.
Review local files once after upgrading; the installation UUID and its grants stay
unchanged. Older device SDKs still connect, but their panels are fetched again
instead of trusting the older hash as a cache key.

Global Full Access intentionally bypasses per-plugin/CLI shell checks while enabled.
It does not approve new local files or install a plugin, and turning it off restores
the individual access levels. Keep it off when testing permission isolation.

### What each kind can do

|  | Device plugin | Desktop plugin |
| --- | --- | --- |
| Binds `necto.device.*` | Yes | Refused at install |
| Binds `necto.desktop.*` | Yes | Yes |
| Calls `necto.desktop.shell.*` | Refused | Subject to shell policy |
| Appears | While its app is connected | Always |
| The agreement | Adding the package to the app | The install dialog |
| Removal | Remove the package from the app | Settings, or delete the folder |
| Same app on several devices | Per-target registration; identical panel content can share a cache | — |

Connection and display behavior:

- Simulator apps share the Mac's loopback, but each SDK instance tries the eight-port
  range starting at its configured base port (9979–9986 by default). The Mac probes
  that range, so several simulator apps can connect while ports remain available.
  USB devices can connect alongside them.
- Device manifests are registered per target. Different apps or devices can carry
  different builds of the same plugin ID without replacing each other's registration.
- A device plugin whose app disconnects stays in the sidebar in gray, drawn from
  the cached panel, and comes back to life when the app does. Only ids are written
  down; right-click offers Forget, and an id the app stops carrying disappears at
  the app's next disconnect.
- Disabling a device plugin hides it on this Mac only: it sinks to the bottom of
  its section, and the registry and the CLI still answer for it.
- Several apps on one device connect and are told apart — but iOS suspends whatever
  is in the background, so only the foreground app reliably answers. A call to a
  suspended app fails with a timeout instead of hanging.

## Operations

Every entry in `operations` declares all of the following. Nothing is optional.

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | Unique within the plugin |
| `title` | string | Human readable name |
| `description` | string | What it does |
| `kind` | `once` \| `stream` | How it answers |
| `binding` | object | Which provider it resolves to |
| `inputSchema` | JSON Schema | Validates the input |
| `outputSchema` | JSON Schema | Validates the output or each stream event |
| `timeoutMs` | integer | Operation time limit in milliseconds; `0` means no operation timeout |

`timeoutMs` is required. Setting it to `0` does not disable limits enforced separately
by the shell provider.

The CLI's `plugin help` uses these existing descriptions and schemas. Keep required
fields, types, enums, and constraints in the schema. Use an operation's `description`
for prerequisites, effects, and where inputs come from, for example:
"First call records.list and pass a returned record's id as recordID."
Schema properties may also have a `description`. This prose is displayed as help,
not parsed as routing or permission rules. No separate help file or new field is
required. See [CLI discovery](control-socket.md#the-discovery-chain).

`kind` determines how it is called:

- `once` answers a single time, via `send`
- `stream` delivers events until it ends, via `subscribe`

Operations do not declare a separate read/write flag. A plugin author's declaration
alone cannot establish safety, so bridge names describe the action, as in
`necto.device.events.clear`.

`binding` names the bridge behind the operation, in two fields:

```json
"binding": {
  "name": "necto.device.network-records.list",
  "version": 1
}
```

The owner is in the name rather than beside it:

- `necto.desktop.…` is answered by the Mac app — storage, targets, the running version.
- `necto.device.…` is answered by a connected app through the SDK, scoped to a
  `(deviceID, appBundleID)` target. Calls without a selected target are refused.

The panel calls its own operation ID through the corresponding side. For example,
an operation named `records.list` that binds `necto.device.network-records.list` is
called with `necto.device.send("records.list")`. A binding name belonging to neither
owner is refused when the manifest is validated.

Two operations may not bind to the same bridge: one power asked for twice would be
shown twice and agreed to twice.

A plugin does not declare whether it needs a connected app. The runtime derives that
from the bindings: one `necto.device.…` means a target is required.

The provider must agree with the manifest on the binding name, version and operation
kind. Input, output and stream events are validated against the manifest's schemas;
provider schemas are not compared for equality. Matching on the name alone could
route an incompatible version or kind to the wrong implementation.


## Discovering and calling operations

Plugin JavaScript never names a provider. It calls an operation id declared in its own
manifest.

```text
manifest.json operations[]
        │ matched against provider descriptors at install time
        ▼
runtime registry (resolve binding name, version and kind; validate payloads)
        │
        ├─ necto.context()                         → availability
        ├─ necto.device.send() / necto.desktop.send() → once
        └─ necto.device.subscribe() / necto.desktop.subscribe() → stream
```

### Discovery

`context()` returns the operations with their current state. There is no separate
listing API.

```js
import { necto } from "@necto/bridge";

const context = await necto.context();

context.operations
// [{ id: "records.list", kind: "once", available: true },
//  { id: "variables.list", kind: "once", available: false,
//    unavailableReason: "The selected app does not provide this operation" }]

context.target  // selected target, or undefined
```

`available: false` means nothing here answers that bridge: no app is selected, the
selected app has not registered it, or the provider's contract disagrees with the
manifest. Show `unavailableReason` to the user as-is and disable the control.

Available operations change with the selected target, so re-read `context()` when
the selection changes.

### Calling

```js
import { necto } from "@necto/bridge";

const page = await necto.device.send("records.list", { limit: 50 });

const subscription = await necto.device.subscribe(
  "records.observe",
  {},
  (event) => appendRow(event),
  (error) => showError(error),
);
await necto.ready();

// When the panel no longer needs updates:
await subscription.unsubscribe();
```

These examples assume the manifest declares `records.list` and `records.observe`.
Call `necto.ready()` after registering stream handlers; the host buffers events until
that call completes.

Input is validated against `inputSchema` and output and stream events against
`outputSchema` at the runtime boundary. Invalid input fails with `INVALID_INPUT`
before the provider runs. Invalid provider output fails with `INVALID_OUTPUT`
before it is delivered to the caller.

### Errors

| Code | Meaning |
| --- | --- |
| `INVALID_INPUT` | Input did not match `inputSchema` |
| `OPERATION_NOT_FOUND` | No such operation id in the manifest |
| `OPERATION_UNAVAILABLE` | Not usable in the current state or surface |
| `PERMISSION_DENIED` | The caller's identity or shell policy does not allow the request |
| `TARGET_DISCONNECTED` | No connected app is selected, or it disconnected |
| `TIMEOUT` | The provider exceeded `timeoutMs` |
| `CANCELLED` | The call was cancelled |
| `PROVIDER_FAILED` | The provider raised an error |
| `INVALID_OUTPUT` | Provider output did not match `outputSchema` |

## Example

```json
{
  "schemaVersion": 1,
  "id": "network-logger",
  "name": "Network Logger",
  "description": "Watch the app's network requests as they happen",
  "version": "1.0.0",
  "author": "Necto",
  "icon": { "systemName": "network" },
  "assets": ["index.html", "assets"],
  "allowedOrigins": ["self"],
  "operations": [
    {
      "id": "records.observe",
      "title": "Observe network records",
      "description": "Receives a change whenever a request is recorded",
      "kind": "stream",
      "binding": {
        "name": "necto.device.network-records.observe",
        "version": 1
      },
      "inputSchema": { "type": "object", "additionalProperties": false },
      "outputSchema": {
        "type": "object",
        "properties": { "record": { "type": "object" } },
        "required": ["record"]
      },
      "timeoutMs": 0
    }
  ]
}
```

## Design notes

**Bindings define requested permissions.** Necto runs web assets and only connects
bridges declared in the manifest. The approval dialog shows these bindings directly.
Approval covers all requested bridges; partial approval could leave a plugin without
the bridges it needs to work.

**No platform flag.** Necto is macOS only, so a flag such as `isDesktopOnly` is
unnecessary. Whether a connected app is required is derived from the bindings.

**Declarations are not enforcement.** `allowedOrigins` is required, but the current
implementation only validates its format. Do not use it as a network security boundary.
