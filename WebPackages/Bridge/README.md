# @necto/bridge

Typed client for the [Necto](../../README.md) plugin bridge.

A Necto plugin is a web page plus a `manifest.json`. The manifest declares the
operations the plugin may call; this package is how you call them.

```bash
NECTO_VERSION=0.1.0
npm install "https://github.com/toss/necto/releases/download/${NECTO_VERSION}/necto-bridge-${NECTO_VERSION}.tgz"
```

## Usage

```ts
import { necto } from "@necto/bridge";

const context = await necto.context();
console.log(context.operations.filter((operation) => operation.available), context.target);

// Answered by the Mac.
const info = await necto.desktop.send<{ nectoVersion: string }>("host.info");

// Answered by the connected app, on a device or a simulator.
await necto.device.subscribe<{ sequence: number }>(
  "records.observe",
  {},
  (event) => console.log(event.sequence),
);

// Register every handler first, then let the host flush buffered events.
await necto.ready();
```

`send` resolves with a single response. `subscribe` receives events and resolves
with a subscription object; call its `unsubscribe()` method to stop receiving events.

## Which side answers

`necto.desktop` is the Mac: storage, targets, and what Necto itself knows.
`necto.device` is the connected app, on a phone or a simulator alike.

The manifest binding determines which side answers. Use the corresponding API at
the call site. Only `device` operations can fail because no app is connected.

## How it works

You never call a bridge name or a provider directly. You call an operation id
declared in your own manifest, and Necto routes it to a trusted provider — one that
was in the list agreed to when the plugin was installed.

```text
necto.desktop.send("host.info")
  └─ manifest operation "host.info"
       └─ binding { name: "necto.desktop.info", version: 1 }
            └─ answered by the Mac app

necto.device.send("records.list")
  └─ manifest operation "records.list"
       └─ binding { name: "necto.device.network-records.list", version: 1 }
            └─ answered by the connected app, through its own plugin
```

Inputs, outputs and stream events are validated against the JSON Schemas in the
manifest before they reach your code, so a resolved promise means the payload
already matches what you declared.

## Errors

Failures reject with an `Error` carrying a `code`:

| Code | Meaning |
| --- | --- |
| `INVALID_INPUT` | Input did not match `inputSchema` |
| `OPERATION_NOT_FOUND` | No such operation in the manifest |
| `OPERATION_UNAVAILABLE` | Not usable in the current state or surface |
| `TARGET_DISCONNECTED` | No connected app is selected, or it disconnected |
| `TIMEOUT` | The provider exceeded `timeoutMs` |
| `CANCELLED` | The call was cancelled |
| `PROVIDER_FAILED` | The provider raised an error |
| `INVALID_OUTPUT` | The provider's output did not match `outputSchema` |

```ts
import { necto, hasErrorCode } from "@necto/bridge";

try {
  await necto.device.send("records.list");
} catch (error) {
  if (hasErrorCode(error, "TARGET_DISCONNECTED")) {
    // ask the user to select a connected app
  }
}
```

## Styling

Import the shared stylesheets to use Necto's design tokens and components.
The host applies the window's appearance, including dark mode.

```ts
import "@necto/bridge/theme.css";       // tokens
import "@necto/bridge/components.css";  // table, toolbar, tabs, status, code
```

```css
.row {
  height: var(--necto-row-height);
  background: var(--necto-surface);
  color: var(--necto-text);
}
```

Never write a colour or a font size as a literal — take it from a token, and add one
if it is missing. The rules and the full token list are in
[docs/design.md](../../docs/design.md), with a live gallery beside it.

Do not add a separate theme toggle; follow the host's appearance setting.

## Localizing a plugin

Necto writes its selected language to the page's standard `<html lang>` attribute
before the plugin script starts. `necto.createTranslator` reads it, falls back to the
source text when a translation is missing, and substitutes named values.

```ts
const t = necto.createTranslator({
  ko: {
    Clear: "비우기",
    "{count} events": "이벤트 {count}개",
  },
});

clearButton.textContent = t("Clear");
count.textContent = t("{count} events", { count: 3 });
```

The plugin owns its translations. Changing the language in Necto safely reloads the
open panel, so its initial render reads the new locale; no SDK or operation contract is
involved.

## Running outside Necto

Every call throws `NectoBridgeUnavailableError` in a plain browser. Guard with
`necto.isAvailable()` when you want the page to render without a host.

## License

MIT
