# The control socket

The control socket lets `necto` (also available as `necto-cli`) and other processes
on the same Mac send requests to the running Necto app.

Operation calls use the same `NectoPluginRegistry` as web panels, with the same route
and payload validation and the same providers. An operation must be declared in an
installed manifest. Requests do not carry a separate `surface: "cli"` authorization flag.

`necto-cli shell run` invokes Necto's internal CLI manifest and uses its dedicated
Shell Access entry in Settings. General `plugin send` and `plugin subscribe`
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
{ "id": "r2", "kind": "plugins", "device": "sim-1", "app": "com.example.app" }
{ "id": "h1", "kind": "plugins", "device": "sim-1", "app": "com.example.app", "pluginID": "network-logger", "operationID": "records.detail" }
{ "id": "h2", "kind": "plugins", "desktop": true }
{ "id": "i1", "kind": "installPlugin", "input": { "path": "/absolute/path/to/dist" } }
{ "id": "i2", "kind": "installPlugin", "input": { "repositoryURL": "https://github.com/owner/plugins" } }
{ "id": "d1", "kind": "deletePlugin", "pluginID": "com.example.plugin" }
{ "id": "r3", "kind": "invoke",    "pluginID": "url-scheme", "operationID": "links.open",
  "input": { "url": "https://example.com" }, "device": "sim-1", "app": "com.example.app" }
{ "id": "r4", "kind": "subscribe", "pluginID": "plugin-sample", "operationID": "host.ticks", "device": "sim-1", "app": "com.example.app" }
{ "id": "r4", "kind": "cancel" }
```

- `plugins` returns plugin summaries for the selected scope. Add `pluginID` to get
  operation summaries; add `operationID` as well to get that operation's full schemas.
- `plugins`, `invoke`, and `subscribe` require both `device` and `app`, or
  `desktop: true`. The pair identifies the app carrying the plugin, even when an
  operation binds a desktop bridge. Desktop scope selects independently installed
  plugins. These scopes never fall back to each other or use the GUI selection.
- Discovery results include `scope` and `target`, followed by `plugins`, `plugin`,
  or `plugin` plus `operation`. Operation details include `available` and, when
  unavailable, `unavailableReason`. Read help again after a plugin update; the
  Registry validates calls against the current manifest.
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
necto device list --json
necto plugin list --device <device-id> --app <bundle-id> --json
necto plugin help <plugin> --device <device-id> --app <bundle-id>
necto plugin help <plugin> <op> --device <device-id> --app <bundle-id> --json
necto plugin send <plugin> <op> --device <device-id> --app <bundle-id> --input '{}'
necto plugin subscribe <plugin> <op> --device <device-id> --app <bundle-id> --limit 10 --timeout 30s
necto plugin list --desktop
necto plugin help <plugin> <op> --desktop
necto plugin send <plugin> <op> --desktop --input-file input.json

necto install owner/plugins --json         # remote is the default
necto install https://github.com/owner/plugins --remote
necto install https://github.com/owner/plugins/releases/tag/v1.2.0
necto install ./dist --local               # approve in Necto; wait for installation
necto install ./my-plugin.zip --local
necto delete com.example.plugin --json     # ID from plugin list; moves files to Trash
necto shell run 'git status --short'       # shell policy is managed in Necto Settings
```

Replace placeholders with IDs from discovery. `device list --json` groups connected
apps (`bundleID`, `name`) under each device (`id`, `name`). `plugin help` reads existing
manifest descriptions and schemas; it does not require a separate help file.
Build inputs from the schema's required fields, types, and constraints. Descriptions
explain workflows but do not define routing or permissions.

`send` prints JSON. `subscribe` prints JSON Lines and stops on completion, a positive
`--limit`, `--timeout` (for example `30s` or `500ms`), or Ctrl+C. Completion and bounds
exit with `0`; Ctrl+C exits with `130`. Remote errors and unexpected disconnects exit
nonzero. Errors go to stderr. Closing the CLI connection cancels its active stream.

Use `--input-file <path>` for large JSON or `--input-file -` for stdin; it cannot be
combined with `--input`. No input means `{}`. `plugin invoke` remains an alias for
`send`; `plugin schema` prints just the input/output schemas with the same required
scope flags. `targets --json` retains the flat target list. Commands that formerly
guessed a target now require an explicit scope; update scripts accordingly.

## Coding agent skills

```bash
necto skills install --codex
necto skills install --claude
necto skills install --codex --claude
```

Both agents use the same bundled `SKILL.md`. Codex installs to
`~/.agents/skills/necto`; Claude Code installs to `~/.claude/skills/necto`. The skill
teaches discovery and schema-based calls rather than listing specific plugins.
It does not change a manifest or install plugin-specific skills.

Installation works without a running Necto app. Repeating it with identical content
does nothing; replacing changed content requires `--force`. The command only writes
the Necto `SKILL.md`, leaving other skills and configuration alone. Reload the agent's
session if it does not discover the new skill.

## CLI setup and plugin installation

`install` defaults to `--remote`; `owner/repo` resolves on GitHub.com and HTTPS
repository/release URLs are accepted. Filesystem folders and ZIPs require `--local`.
`--local` and `--remote` are mutually exclusive. `necto plugin install` and
`necto-cli plugin install` accept the same options. In Settings → General → Command
line tool, click **Install CLI** and approve the macOS administrator prompt. This
links `necto` and `necto-cli` in `/usr/local/bin` to the bundled executable. Existing
files or links to another executable are not overwritten. The CLI and its bundled
skill update with the app. Run `skills install`
again to update an installed skill; review the difference before using `--force`.

`necto plugin delete <pluginID>` and `necto-cli plugin delete <pluginID>` are also supported.
Deletion is explicit and does
not ask for a second installation approval; it does not delete a GitHub repository.

Use `necto install --help`, `necto delete --help` or `necto plugin --help` for options.
