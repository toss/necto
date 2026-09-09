//
//  Copyright (c) 2026 Viva Republica, Inc.
//

export function installDetailFixture() {
  const event = { id: "event-1", at: 1, level: "info", tag: "Example", message: "A long event message for checking detail pane layouts", hasDetail: true, detail: { source: "Example" } };
  const entry = { key: "example.preferences", type: "string", preview: "example", value: "example", isTruncated: false };
  const file = { name: "example.json", isDirectory: false, size: 20, kind: "text", text: '{"example": true}' };
  const replies = {
    "events.list": { events: [event] }, "events.detail": { event },
    "preferences.suites": { suites: ["standard"] }, "preferences.list": { entries: [entry] }, "preferences.detail": { entry },
    "files.roots": { roots: [{ id: "documents", name: "Documents" }] }, "files.list": { entries: [file] },
    "files.preview": { file }, "files.info": { item: file },
  };
  window.webkit = { messageHandlers: { necto: { async postMessage(message) {
    if (message.type === "ready") return { ok: true, value: null };
    if (message.type === "subscribe") return { ok: true, value: "fixture" };
    if (message.operationID in replies) return { ok: true, value: replies[message.operationID] };
    return { ok: false, error: { code: "OPERATION_NOT_FOUND", message: `Missing fixture: ${message.operationID}` } };
  } } } };
}
