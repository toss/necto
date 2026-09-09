# The control socket

The control socket lets `necto` (also available as `necto-cli`) and other processes
on the same Mac send requests to the running Necto app.

Operation calls use the same `NectoPluginRegistry` as web panels, with the same route
and payload validation and the same providers. An operation must be declared in an
installed manifest. Requests do not carry a separate `surface: "cli"` authorization flag.

`necto-cli shell run` invokes Necto's internal CLI manifest and uses its dedicated
Shell Access entry in Settings. General `plugin invoke` and `plugin subscribe`
requests instead run as the plugin selected by `pluginID`, including that plugin's
shell permissions when it exposes a shell operation. The socket trusts processes
running as the local OS user; it does not authenticate plugin ownership or isolate
general CLI calls from plugin grants. See [shell access](bridges.md#shell-access).

## Where and how

- **Socket**: `~/Library/Application Support/Necto/necto.sock`, created `0600` by the
  app on launch. The boundary is the user account — the same boundary as the plugins
  folder beside it.
- **Framing**: every message is a 4-byte big-endian length followed by that many bytes
  of JSON. The same framing every Necto connection uses.
- **Connection**: connect, send requests, read responses. Requests on one connection
  may interleave; `id` pairs each response with its request. Closing the connection
  cancels the streams it started.

## Requests

```json
{ "id": "r1", "kind": "targets" }
{ "id": "r2", "kind": "plugins" }
{ "id": "i1", "kind": "installPlugin", "input": { "path": "/absolute/path/to/dist" } }
{ "id": "i2", "kind": "installPlugin", "input": { "repositoryURL": "https://github.com/owner/plugins" } }
{ "id": "d1", "kind": "deletePlugin", "pluginID": "com.example.plugin" }
{ "id": "r3", "kind": "invoke",    "pluginID": "url-scheme", "operationID": "links.open",
  "input": { "url": "https://example.com" }, "app": "com.example.app" }
{ "id": "r4", "kind": "subscribe", "pluginID": "plugin-sample", "operationID": "host.ticks" }
{ "id": "r4", "kind": "cancel" }
```

- `pluginID` and `operationID` are the ids from `plugins` — the installed manifests.
  Query this list to discover currently callable operations instead of hardcoding them.
- `app` selects a connected app by bundle ID for device operations. If that app runs
  on several devices, also set `device` to the device ID from `targets`.
  The selection must identify exactly one connected target; otherwise the request fails.
- `cancel` reuses the `id` of the pending request or subscription it stops.

`installPlugin` accepts exactly one absolute local folder/ZIP `path` or HTTPS
`repositoryURL`. URL inputs cannot contain credentials, ports, queries or fragments.
The app uses the same release lookup, download, staging, validation, source
confirmation and commit flow as Settings. It opens the
installation approval in Necto and returns only after the approved snapshot is
registered. No plugin bridge or shell permission is used to install a plugin.
Another in-progress installation is refused rather than replaced.

Repository URLs use the latest release unless a `/releases/tag/<tag>` URL is given.
If a release holds several plugins, choose one in Necto; one CLI invocation installs
one chosen plugin. The repository/tag origin is recorded just as it is for a GUI
installation, so later updates retain their source identity. Cancelling abandons
pending release/download work and discards any late results before staging.

Repository authentication has the same requirements as the existing GUI release
source: public repositories can download directly; private/Enterprise access currently
uses the developer's `gh` login. Installer authentication is separate from credentials
managed by individual plugins. CLI installation does not change that mechanism.

A successful install returns `installed: true`, `pluginID`, `name`, `version` and
`enabled`. Updating an existing ID still requires source confirmation; existing
disabled state is preserved. Invalid files, device-bound plugins and declined
approvals fail. `cancel` or disconnecting the CLI closes a pending approval. Once
the user has approved and committing has started, the installation may complete
even if the CLI exits. This is not an unattended or approval-bypassing install API.

## Responses

```json
{ "id": "r3", "kind": "result", "value": { "opened": true } }
{ "id": "r4", "kind": "event",  "value": { "sequence": 1 } }
{ "id": "r4", "kind": "end" }
{ "id": "r3", "kind": "error",  "error": { "code": "INVALID_INPUT", "message": "url is required" } }
```

A request sees exactly one `result` or `error` — except `subscribe`, which sees any
number of `event`s and then one `end` or `error`. Error codes are the bridge's own
(`docs/plugin-manifest.md` lists them), forwarded from the registry.

## The discovery chain

`deletePlugin` takes an installed desktop plugin ID, never a path or repository URL.
It uses the same removal path as Settings: moves the plugin folder to Trash, revokes
its grants and installation record, unregisters it, and stops its panel/background
lifetime. It returns `deleted: true` and `pluginID` after completion. Unknown IDs and
device plugins fail without deleting files. Installation and deletion are serialized
by the same coordinator; a pending install/approval must finish first.

```bash
necto-cli plugin list                      # installed plugins and their operations
necto install owner/plugins --json         # remote is the default
necto install https://github.com/owner/plugins --remote
necto install https://github.com/owner/plugins/releases/tag/v1.2.0
necto install ./dist --local               # approve in Necto; wait for installation
necto install ./my-plugin.zip --local
necto delete com.example.plugin --json     # ID from plugin list; moves files to Trash
necto-cli plugin schema <plugin> <op>      # what one operation takes and returns
necto-cli plugin invoke <plugin> <op> --input '{}'
necto-cli plugin invoke <plugin> <op> --input '{}' --app <bundle-id> --device <device-id>
necto-cli plugin subscribe <plugin> <op>   # one JSON object per line, ^C cancels
necto-cli targets --json                   # includes bundle ids and device ids
necto-cli shell run 'git status --short'   # shell policy is managed in Necto Settings
```

Replace the placeholders with values from `plugin list` and `targets --json`, and
build `--input` from the operation's `schema`. `schema` and `invoke` already print
JSON; `subscribe` prints one JSON event per line. For `targets` and `plugin list`,
use `--json` to select JSON instead of the default human-readable output.
`subscribe` also accepts `--app` and `--device`.

`install` defaults to `--remote`; `owner/repo` resolves on GitHub.com and HTTPS
repository/release URLs are accepted. Filesystem folders and ZIPs require `--local`.
`--local` and `--remote` are mutually exclusive. `necto plugin install` and
`necto-cli plugin install` accept the same options. Copy and run the command shown in
Settings → About to link both `necto` and `necto-cli` to the bundled executable on
your `PATH`. Existing commands remain usable; after updating Necto, run that command
again if only `necto-cli` is available.

`necto plugin delete <pluginID>` and `necto-cli plugin delete <pluginID>` are also supported.
Deletion is explicit and does
not ask for a second installation approval; it does not delete a GitHub repository.

Use `necto install --help`, `necto delete --help` or `necto plugin --help` for options.
