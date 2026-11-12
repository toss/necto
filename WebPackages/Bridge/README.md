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

## Usage events

A plugin decides when to record an event and what it means:

```ts
necto.log("note.opened", { source: "sidebar" });
necto.log("notes.refreshed"); // params defaults to {}
```

`necto.log(eventName, params?)` returns `void` immediately. It is best effort and
provides no delivery receipt. Host failures produce a generic console warning
without the event's params or the host's error payload. In a plain browser preview,
the call is a quiet no-op.

`params` is a JSON object; event names and params do not require manifest schemas.
The host supplies event identity, timestamps, installation and plugin metadata.
Events from the WebView have `channel: "web"`, including timers and background
callbacks. Use the same event name for the same meaning across web and CLI entry
points; the channel distinguishes where it came from. This API records web-plugin
events. App plugins use `NectoRegistrar.logger`; calls originating in web or CLI
handlers carry that channel automatically.

## Event exporters and diagnostics

A desktop plugin with `"type": "event-exporter"` in its manifest registers its
event callback with the host:

```ts
await necto.registerExporter({
  onEvent(event) {
    console.log(event.eventName, event.params);
  },
});
```

The callbacks are installed before the registration request, so events can arrive
before the promise resolves. This API does not require `necto.ready()`. Register
once per page. A duplicate rejects without replacing the callbacks, and a failed
registration removes them so it can be retried. The host unregisters the exporter
when the page ends or the plugin is removed.

Pass an optional `onShutdown({ deadlineAt })` callback to finish accepted work
during normal app shutdown. New `onEvent` calls stop before the hook runs. The
host waits up to five seconds for the hook's returned promise, and `deadlineAt`
gives the absolute deadline in Unix epoch milliseconds. HTTP, storage and
diagnostics remain available during the hook. The exporter owns any pending
asynchronous `onEvent` work and can use the hook to flush or persist it. A thrown
or rejected hook is reported as a local diagnostic.

`NectoEvent` includes `eventId`, `occurredAt` (Unix milliseconds), `installationId`,
`nectoVersion`, `eventName`, `params`, and an optional `channel` (`web` or `cli`).
The host sets `origin` to `device`, `desktop`, or `necto`. Device and desktop events
include `pluginId`. Desktop events include `pluginVersion`; device events include it
only when the connected app carries a manifest for that plugin. Necto events may
include `relatedPluginId`.

Write local diagnostics separately:

```ts
await necto.diagnostics.log("warning", "Delivery pending", { count: 2 });
```

Levels are `info`, `warning`, and `failure`; metadata is an optional JSON object.
Diagnostics appear in Necto's native diagnostic log and are not delivered as
exporter events. A thrown or rejected `onEvent` callback is reported there as a
failure. A failure to write that diagnostic does not trigger another report.

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

Bridge requests that return promises reject with `NectoBridgeUnavailableError` in
a plain browser. Guard with `necto.isAvailable()` when you want the page to render
without a host. `necto.log()` is a quiet no-op without a host.

## License

MIT
