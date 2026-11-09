# @necto/http-exporter

`HTTPExporter` is a receiver for a Necto desktop event exporter plugin. It batches
events and sends them to an HTTPS endpoint through the Necto desktop bridge.

## Use in your plugin

Install both packages from the same Necto release that includes HTTPExporter.
Replace `x.y.z` with that release version.

```bash
NECTO_VERSION=x.y.z
RELEASE_URL="https://github.com/toss/necto/releases/download/$NECTO_VERSION"
npm install \
  "$RELEASE_URL/necto-bridge-$NECTO_VERSION.tgz" \
  "$RELEASE_URL/necto-http-exporter-$NECTO_VERSION.tgz"
```

Set `"type": "event-exporter"` in your plugin manifest and copy the four operations
from the [example manifest](https://github.com/toss/necto/blob/main/WebPackages/HTTPExporter/example/public/manifest.json).
Keep the operation IDs and bindings as shown there. Register the receiver once
from your plugin's entry point.

```ts
import { necto } from "@necto/bridge";
import { HTTPExporter } from "@necto/http-exporter";

await necto.registerExporter(new HTTPExporter({
  url: "https://collector.example.invalid/events",
}));
```

| Option | Default | Meaning |
| --- | --- | --- |
| `url` | Required | Absolute HTTPS endpoint |
| `headers` | `Content-Type: application/json` | Additional request headers. An explicit `Content-Type` overrides the default. |
| `maxEvents` | `100` | Waiting-event count that triggers a send; the request includes the whole waiting queue |
| `maxInterval` | `60000` | Time in milliseconds before a healthy partial batch is eligible to send |
| `maxQueuedEvents` | `10000` | Maximum waiting events, separate from the active request |

The numeric options accept positive safe integers. Treat any headers in a built
plugin as readable by anyone with its files.

## Build and install the example

From the Necto checkout, change the placeholder endpoint in
[`example/src/main.ts`](https://github.com/toss/necto/blob/main/WebPackages/HTTPExporter/example/src/main.ts)
to your collector, then run these commands from the repository root.

```bash
corepack enable
yarn install --immutable
yarn workspace @necto/bridge build
yarn workspace @necto/http-exporter build
yarn workspace @necto-plugin/http-exporter-example build
```

In Necto, go to **Settings → Desktop Plugins → Install from a file → Choose…**
and select `WebPackages/HTTPExporter/example/dist`. Review the requested HTTP
and storage access and approve installation to enable collection. The example
runs in a hidden page, and its diagnostics appear under **Settings → Event Exporter**.

## Delivery behavior

The exporter sends one request at a time. At the start of each request, it takes
all waiting events; `maxEvents` is a trigger, not a per-request limit. Events that
arrive during a request wait in the next queue. Each request is a `POST` whose UTF-8
JSON body is an object with an `events` array of `NectoEvent` records. A `2xx`
response completes the batch. `4xx` responses other than `408` and `429` discard
the batch and write a local diagnostic. Network errors, `408`, `429`, `5xx`, and
other unexpected non-success responses retry after 5, 10, 20, 40, then 60 seconds,
with subsequent retries at 60 seconds. A valid `Retry-After` can extend the wait.
When the waiting queue fills, the oldest waiting events are dropped.
Retry delays take precedence over `maxInterval`; that interval is not a delivery
deadline while a request is active or the collector is failing.

The exporter checkpoints pending events after a retryable failure and updates an
existing checkpoint as batches resolve. During normal shutdown it first saves
pending events and then attempts delivery within the host's deadline and the
retry schedule. A reload restores saved events with their original `eventId`s.
Queued saves are coalesced so repeated updates write the latest pending state
without accumulating a write for every event. Storage uses the plugin's own
namespace at `http-exporter.pending` and contains
the pending event records. Use `eventId` to deduplicate on the receiving side.
The checkpoint format is versioned; incompatible values are skipped with a
diagnostic. Retry timers are in memory and start afresh after a reload.
An interruption before a successful checkpoint can lose unsaved events, and an
interruption after delivery can cause the saved batch to be sent again.
