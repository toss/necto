# Part 1 — Your first desktop plugin

A plugin is a web page plus a `manifest.json`. This tutorial builds one from
scratch and installs it in Necto — no app, no Swift, no Xcode. Every step shows
the complete file, so you can copy each block in order and end with a working
plugin.

## What we build

**Who Is Connected**: a panel that shows which version of Necto is running and a
live table of every app Necto can see — on a simulator, on a USB device, connected
or merely discovered. Everything it needs, the Mac already knows, which is what
makes it a *desktop* plugin: it binds only `necto.desktop.*` bridges and installs
in Necto itself, while a *device* plugin binds `necto.device.*` and rides inside
the app it debugs. [plugin-manifest.md](plugin-manifest.md) has the full story of
the two kinds; [bridges.md](bridges.md) lists everything a plugin can bind to.

You need Node 22.12 or later and a built [Necto app](https://github.com/toss/toss-necto#getting-started).

## The folder

A plugin is built like any small web page. Start a folder:

```bash
mkdir who-is-connected && cd who-is-connected
mkdir public src
```

`package.json` — the bridge client plus a bundler:

```json
{
  "name": "who-is-connected",
  "private": true,
  "type": "module",
  "scripts": {
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

`vite.config.js` — relative paths, because the panel is served from a folder
rather than a domain. `manifest.json` lives in `public/` so the build copies it
next to `index.html`:

```js
import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "dist",
  },
});
```

`public/manifest.json` is the contract: it declares the operations the plugin may
call, and anything not declared here is not connected by the runtime.

```json
{
  "schemaVersion": 1,
  "id": "com.example.who-is-connected",
  "name": "Who Is Connected",
  "description": "Every app Necto can see, as it changes",
  "version": "1.0.0",
  "author": "You",
  "icon": { "systemName": "dot.radiowaves.left.and.right" },
  "assets": ["index.html", "assets"],
  "allowedOrigins": ["self"],
  "operations": [
    {
      "id": "host.info",
      "title": "Host info",
      "description": "Reads the Necto version and protocol version",
      "kind": "once",
      "binding": { "name": "necto.desktop.info", "version": 1 },
      "inputSchema": {
        "type": "object",
        "properties": {},
        "additionalProperties": false
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "nectoVersion": { "type": "string" },
          "protocolVersion": { "type": "number" }
        },
        "required": ["nectoVersion", "protocolVersion"],
        "additionalProperties": true
      },
      "timeoutMs": 3000
    },
    {
      "id": "targets.observe",
      "title": "Observe targets",
      "description": "Receives the full target list whenever it changes",
      "kind": "stream",
      "binding": { "name": "necto.desktop.targets.observe", "version": 1 },
      "inputSchema": {
        "type": "object",
        "properties": {
          "includeDiscovered": { "type": "boolean" }
        },
        "additionalProperties": false
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "targets": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "targetHandle": { "type": "string" },
                "name": { "type": "string" },
                "appName": { "type": "string" },
                "appBundleID": { "type": "string" },
                "deviceType": { "type": "string" },
                "isConnected": { "type": "boolean" }
              },
              "required": ["targetHandle", "appName", "appBundleID", "deviceType", "isConnected"],
              "additionalProperties": true
            }
          }
        },
        "required": ["targets"],
        "additionalProperties": true
      },
      "timeoutMs": 0
    }
  ]
}
```

Field by field:

- `schemaVersion` — the manifest format, `1`.
- `id` — stable identifier, `[A-Za-z0-9._-]+`, separate from the display name.
  Lowercase reverse-domain is recommended; choose your namespace before distribution.
- `name`, `description`, `version`, `author` — what the sidebar and the install
  dialog show.
- `icon` — an SF Symbols name, drawn by the shell in the sidebar.
- `assets` — the files and directories to package; `assets` is where Vite puts
  the bundle.
- `allowedOrigins` — origin declarations; this example uses `self` for the plugin's
  own files. Currently only the declaration format is validated; external traffic is not blocked.
- `operations` — every call the plugin may make. Each entry names the operation
  id your JavaScript calls, the `binding` that says which bridge answers it, a
  `kind` (`once` answers a single time, `stream` delivers events until it ends),
  and the JSON Schemas the runtime validates every payload against.

Both bindings start with `necto.desktop.` and are answered by the Mac app.
The final section demonstrates why device bindings are refused during desktop
installation. See [plugin-manifest.md](plugin-manifest.md) for versioning and the
complete format.

## The panel

`index.html` — the page Necto loads:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="color-scheme" content="light dark" />
    <title>Who Is Connected</title>
  </head>
  <body>
    <div class="necto-app">
      <div class="necto-toolbar">
        <span class="necto-badge" id="version">Necto</span>
        <span class="necto-caption" id="count">0 targets</span>
      </div>

      <div class="necto-body">
        <table class="necto-table" id="table" hidden>
          <thead>
            <tr>
              <th>App</th>
              <th>Bundle id</th>
              <th>Device</th>
              <th>State</th>
            </tr>
          </thead>
          <tbody id="rows"></tbody>
        </table>

        <div class="necto-empty" id="empty">
          <p class="necto-empty-title">No targets yet</p>
          <p class="necto-caption">Run an app with the Necto SDK on a simulator or a USB device.</p>
        </div>
      </div>
    </div>

    <script type="module" src="./src/main.js"></script>
  </body>
</html>
```

`src/main.js` — the whole behaviour. Inside Necto's WebView the host answers
through a WebKit message handler; `@necto/bridge` wraps it, and your code only
ever names operation ids from its own manifest — never a bridge, never a
provider:

```js
import { necto } from "@necto/bridge";
import "./style.css";

const version = document.getElementById("version");
const count = document.getElementById("count");
const table = document.getElementById("table");
const rows = document.getElementById("rows");
const empty = document.getElementById("empty");

function cell(text) {
  const td = document.createElement("td");
  td.textContent = text;
  return td;
}

function stateCell(isConnected) {
  const td = document.createElement("td");
  const mark = document.createElement("span");
  mark.className = isConnected
    ? "necto-status necto-status-ok"
    : "necto-status necto-status-idle";
  mark.textContent = isConnected ? "connected" : "seen";
  td.append(mark);
  return td;
}

function render(targets) {
  rows.replaceChildren();
  for (const target of targets) {
    const row = document.createElement("tr");
    row.append(
      cell(target.appName),
      cell(target.appBundleID),
      cell(target.deviceType),
      stateCell(target.isConnected),
    );
    rows.append(row);
  }
  table.hidden = targets.length === 0;
  empty.hidden = targets.length > 0;
  count.textContent = targets.length === 1 ? "1 target" : `${targets.length} targets`;
}

async function main() {
  if (!necto.isAvailable()) {
    empty.querySelector(".necto-empty-title").textContent =
      "This page must run inside Necto";
    return;
  }

  const info = await necto.desktop.send("host.info");
  version.textContent = `Necto ${info.nectoVersion}`;

  await necto.desktop.subscribe(
    "targets.observe",
    { includeDiscovered: true },
    (event) => render(event.targets),
  );

  // Every handler is registered; the host flushes anything it buffered.
  await necto.ready();
}

void main();
```

`necto.desktop.send` asks once and waits; `necto.desktop.subscribe` keeps
receiving until you stop. The stream starts with the current list and sends the
full list on every change, so the panel updates the table through `render`. Input
and output are validated against the manifest schemas before they reach your
code, and failures reject with an `Error` carrying a `code` —
[WebPackages/Bridge/README.md](https://github.com/toss/toss-necto/blob/main/WebPackages/Bridge/README.md) documents the full API and every
error code.

## Make it look native

`src/style.css` — import the two shared stylesheets and the panel is drawn from
the same tokens as the app, following the window into dark mode with no theme
code of your own:

```css
@import "@necto/bridge/theme.css";
@import "@necto/bridge/components.css";

html,
body,
.necto-app {
  height: 100%;
}
```

Everything in the HTML above — `necto-toolbar`, `necto-table`, `necto-badge`,
`necto-status`, `necto-empty` — comes from `components.css`, as plain CSS on
plain elements. Anything of your own takes its colours and sizes from the
tokens (`var(--necto-text)`, `var(--necto-space-3)`, …), never from a literal.
[design.md](design.md) has the token list and the rules, and
`script/serve-design` renders a live gallery of every component.

Now build it:

```bash
npm install
npm run build
```

`dist/` now holds `index.html`, the bundle under `assets/`, and `manifest.json`
— a complete plugin.

## Install it

You can start installation from the terminal while Necto is running. Copy and run
the CLI setup command in Settings → About, then run `necto install dist --local --json`
and approve the source and bridges in Necto. The command waits for the completed
installation. For options and removal with `necto delete <pluginID>`, see the
[CLI guide](control-socket.md).

In Necto, open Settings → Desktop Plugins and click Choose… to select the `dist`
folder. ZIP files also work, including release archives with a wrapper folder and
archives created in Finder.

Before saving plugin files, Necto shows the approval sheet with the plugin's source
and every bound bridge. Host-provided descriptions include
"Which version of Necto is running" and "Which apps and devices are connected".
Approval installs the plugin; declining leaves no plugin files.
See [plugin-manifest.md](plugin-manifest.md) for why approval covers all bindings
without separate permission names.

Approve, and Who Is Connected appears in the sidebar. Launch an app that
[carries the Necto SDK](setup.md) on a simulator and the table gains a row as it
connects.

Installed plugins live in `~/Library/Application Support/Necto/Plugins`, one
folder per plugin id — the Desktop Plugins settings page has Open and Reload buttons for
it. New or changed folders need source confirmation after Reload; an approved
folder shadows the same ID carried by a connected app. To iterate on *this*
plugin, run `npm run build` and install the new `dist` again. Confirming that it
updates the same ID preserves its installation UUID and permissions. Removing the
plugin revokes that identity; a subsequent install starts fresh. Read the
[trust policy](plugin-manifest.md#identity-and-trust) before confirming local updates.

## See a refusal

Add one operation to `public/manifest.json` that a connected app would have to
answer:

```json
{
  "id": "records.list",
  "title": "List network records",
  "description": "Reads the app's request log",
  "kind": "once",
  "binding": { "name": "necto.device.network-records.list", "version": 1 },
  "inputSchema": { "type": "object", "additionalProperties": false },
  "outputSchema": { "type": "object", "additionalProperties": true },
  "timeoutMs": 3000
}
```

Build and choose `dist` again. The install is refused before the approval sheet
ever appears:

> This plugin binds to 'necto.device.network-records.list', which a connected
> app answers. A plugin that needs the app rides in the app: add its Swift
> package there, and it appears here on its own.

Desktop installation rejects device bindings. Device plugins ship their panels
and native implementations together in the app. Rebuild and test committed panel
assets when their source changes.
Remove the operation, rebuild, and the plugin installs again.

## Where next

- Giving it to someone else: [publishing.md](publishing.md)
- Part 2 — your first device plugin: [tutorial-device.md](tutorial-device.md)
- Everything a plugin can bind to: [bridges.md](bridges.md)
- The manifest, operation by operation: [plugin-manifest.md](plugin-manifest.md)
- Tokens, components and the gallery: [design.md](design.md)
- The bridge client's full API: [WebPackages/Bridge/README.md](https://github.com/toss/toss-necto/blob/main/WebPackages/Bridge/README.md)
