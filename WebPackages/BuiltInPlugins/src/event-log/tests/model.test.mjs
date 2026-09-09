//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import test from "node:test";

import {
  availableTags,
  eventDetailContent,
  eventMatches,
  previewMessage,
  upsertBoundedEvent,
  visibleEvents,
} from "../src/model.ts";

const events = [
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
  assert.equal(eventMatches(events[1], "request", "error"), true);
  assert.equal(eventMatches(events[1], "auth", "error"), false);
});

test("event category filter composes with search and level", () => {
  assert.deepEqual(availableTags(events), ["Auth", "Cache", "Network"]);
  assert.deepEqual(visibleEvents(events, "request", "error", "Network").map(({ id }) => id), ["2"]);
  assert.deepEqual(visibleEvents(events, "request", "error", "Auth"), []);
  assert.equal(eventMatches(events[1], "request", "error", "Network"), true);
});

test("event list renders a bounded preview without changing searchable source text", () => {
  const longMessage = `start-${"x".repeat(600)}-needle`;

  assert.equal(previewMessage(longMessage, 50).length, 50);
  assert.equal(previewMessage(longMessage, 50).endsWith("…"), true);
  assert.equal(previewMessage("first line\n  second line"), "first line second line");
  assert.deepEqual(
    visibleEvents([{ ...events[0], message: longMessage }], "needle", "").map(({ id }) => id),
    ["1"],
  );
});

test("live events stay bounded to the newest rows", () => {
  const rows = new Map(events.map((event) => [event.id, event]));
  const newest = { id: "4", at: 400, level: "info", tag: "Live", message: "new", hasDetail: true };

  assert.deepEqual(upsertBoundedEvent(rows, newest, 3), ["1"]);
  assert.deepEqual([...rows.keys()].sort(), ["2", "3", "4"]);

  assert.deepEqual(upsertBoundedEvent(rows, { ...newest, message: "updated" }, 3), []);
  assert.equal(rows.get("4")?.message, "updated");
  assert.equal(rows.size, 3);
});

test("event detail keeps top-level message and metadata alongside adapter fields", () => {
  const content = eventDetailContent({
    ...events[1],
    detail: { source: "TossLogger" },
  });

  assert.equal(content.message, "Request failed");
  assert.deepEqual(content.fields, [
    ["level", "error"],
    ["category", "Network"],
    ["source", "TossLogger"],
  ]);
});
