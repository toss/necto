//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { assert, test } from "vitest";

import {
  availableTags,
  eventDetailContent,
  eventMatches,
  previewMessage,
  upsertBoundedEvent,
  visibleEvents,
  type EventRow,
} from "../src/model";

const events: EventRow[] = [
  { id: "1", at: 100, level: "info", tag: "Auth", message: "Signed in", hasDetail: false },
  { id: "2", at: 300, level: "error", tag: "Network", message: "Request failed", hasDetail: true },
  { id: "3", at: 200, level: "warn", tag: "Cache", message: "Entry evicted", hasDetail: false },
];

test("event search matches level, tag, and message and keeps newest first", () => {
  assert.deepEqual(visibleEvents(events, "auth", "").map(({ id }) => id), ["1"]);
  assert.deepEqual(visibleEvents(events, "ERROR", "").map(({ id }) => id), ["2"]);
  assert.deepEqual(visibleEvents(events, "entry", "").map(({ id }) => id), ["3"]);
  assert.deepEqual(visibleEvents(events, "", "").map(({ id }) => id), ["2", "3", "1"]);
});

test("event search and level filter are combined", () => {
  assert.deepEqual(visibleEvents(events, "request", "error").map(({ id }) => id), ["2"]);
  assert.deepEqual(visibleEvents(events, "auth", "error"), []);
  assert.strictEqual(eventMatches(events[1], "request", "error"), true);
  assert.strictEqual(eventMatches(events[1], "auth", "error"), false);
});

test("event category filter composes with search and level", () => {
  assert.deepEqual(availableTags(events), ["Auth", "Cache", "Network"]);
  assert.deepEqual(visibleEvents(events, "request", "error", "Network").map(({ id }) => id), ["2"]);
  assert.deepEqual(visibleEvents(events, "request", "error", "Auth"), []);
  assert.strictEqual(eventMatches(events[1], "request", "error", "Network"), true);
});

test("event list renders a bounded preview without changing searchable source text", () => {
  const longMessage = `start-${"x".repeat(600)}-needle`;

  assert.strictEqual(previewMessage(longMessage, 50).length, 50);
  assert.strictEqual(previewMessage(longMessage, 50).endsWith("…"), true);
  assert.strictEqual(previewMessage("first line\n  second line"), "first line second line");
  assert.deepEqual(
    visibleEvents([{ ...events[0], message: longMessage }], "needle", "").map(({ id }) => id),
    ["1"],
  );
});

test("live events stay bounded to the newest rows", () => {
  const rows = new Map(events.map((event) => [event.id, event]));
  const newest: EventRow = { id: "4", at: 400, level: "info", tag: "Live", message: "new", hasDetail: true };

  assert.deepEqual(upsertBoundedEvent(rows, newest, 3), ["1"]);
  assert.deepEqual([...rows.keys()].sort(), ["2", "3", "4"]);

  assert.deepEqual(upsertBoundedEvent(rows, { ...newest, message: "updated" }, 3), []);
  assert.strictEqual(rows.get("4")?.message, "updated");
  assert.strictEqual(rows.size, 3);
});

test("event detail keeps top-level message and metadata alongside adapter fields", () => {
  const content = eventDetailContent({
    ...events[1],
    detail: { source: "TossLogger" },
  });

  assert.strictEqual(content.message, "Request failed");
  assert.deepEqual(content.fields, [
    ["level", "error"],
    ["category", "Network"],
    ["source", "TossLogger"],
  ]);
});
