//
// Copyright (c) 2026 Viva Republica, Inc.
//

// Run against a freshly launched ExampleApp using its dedicated fixture bundle.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

const [device, app] = process.argv.slice(2);
if (!device || !app?.startsWith("im.toss.necto.example.")) {
  throw new Error("Usage: node script/tests/control-e2e.mjs <device-id> <dedicated-example-bundle-id>");
}
const executable = process.env.NECTO_CLI ?? "necto";
const scope = ["--device", device, "--app", app];
function send(operation, input = {}) {
  return JSON.parse(execFileSync(executable, ["plugin", "send", "control", `control.${operation}`,
    ...scope, "--input", JSON.stringify(input)], { encoding: "utf8", timeout: 10_000 }));
}
const targets = () => send("actionTargets").targets;
const read = (query) => send("readAccessibility", query ? { query } : {}).items;
const identifier = (value) => (target) => target.identifier === value;
const label = (value) => (target) => target.label === value;
const screen = (target) => target.role === "screen";
async function act(operation, match, input = {}) {
  const matches = targets().filter(match);
  assert.equal(matches.length, 1, `Expected one ${operation} target: ${JSON.stringify(matches)}`);
  const result = send(operation, { targetID: matches[0].id, ...input });
  assert.equal(result.dispatched, true);
  assert.equal(typeof result.contentChanged, "boolean");
  return matches[0].id;
}
async function expectContent(query, match) {
  for (let attempt = 0; attempt < 20; attempt++) {
    if (read(query).some(match)) return;
    await delay(100);
  }
  assert.fail(`Expected content for ${query}: ${JSON.stringify(read(query))}`);
}

const connectionDeadline = Date.now() + 10_000;
while (true) {
  const catalog = JSON.parse(execFileSync(executable, ["device", "list", "--json"], { encoding: "utf8", timeout: 5000 }));
  if (catalog.devices.some((item) => item.id === device && item.apps.some((item) => item.bundleID === app))) break;
  assert.ok(Date.now() < connectionDeadline, "The dedicated ExampleApp did not connect");
  await delay(100);
}
execFileSync(executable, ["plugin", "list", ...scope, "--json"], { encoding: "utf8" });
execFileSync(executable, ["plugin", "help", "control", ...scope, "--json"], { encoding: "utf8" });

await act("tap", label("Accessibility"));
assert.ok(!targets().some(label("Disabled button")));
const oldID = await act("tap", identifier("ax.tap"));
await expectContent("ax.status", (item) => item.label === "Taps: 1");
const stale = spawnSync(executable, ["plugin", "send", "control", "control.tap", ...scope,
  "--input", JSON.stringify({ targetID: oldID })], { encoding: "utf8", timeout: 10_000 });
assert.notEqual(stale.status, 0);
assert.match(stale.stderr, /OPERATION_UNAVAILABLE/);
await act("input", identifier("ax.query"), { text: "테스트" });
await expectContent("ax.query", (item) => item.value === "테스트");
await act("input", identifier("ax.query"), { text: " 추가", mode: "append" });
await expectContent("ax.query", (item) => item.value === "테스트 추가");
await act("input", identifier("ax.query"), { text: "" });
assert.ok(!read("ax.query").some((item) => item.value?.includes("테스트")));
await act("tap", label("Open detail"));
await expectContent("Accessibility Detail", (item) => item.label === "Accessibility Detail");
await act("back", screen);
await expectContent("ax.tap", (item) => item.label === "Count tap");
await act("swipe", (target) => target.role === "scrollArea", { direction: "up", distanceRatio: 0.6, durationMs: 400 });
await delay(1000);
assert.ok(!targets().some(identifier("ax.row.1")), "SwiftUI scroll should move Row 1 offscreen");
console.log("PASS SwiftUI: tab, tap, Unicode replace/append/clear, navigation, edge-back, swipe, stale ID");

await act("tap", label("Control"));
assert.ok(!targets().some((target) => ["poc.trap", "poc.readonly"].includes(target.identifier)));
await act("tap", identifier("poc.nav"));
await act("tap", identifier("poc.tap"));
await act("tap", identifier("poc.gesture"));
await expectContent("poc.status", (item) => item.label === "Taps: 1 · Nav: 1 · Trap: 0 · Gesture: 1");
const gestures = targets().find(identifier("poc.multitap"))?.tapGestures;
assert.equal(gestures?.length, 15, "Discover each native tap configuration");
for (let touchCount = 1; touchCount <= 5; touchCount++) {
  for (let tapCount = 1; tapCount <= 3; tapCount++) {
    await act("tap", identifier("poc.multitap"), { touchCount, tapCount });
    await expectContent("poc.inputStatus", (item) => item.label === `Gesture: ${touchCount} fingers × ${tapCount} taps`);
  }
}
console.log("PASS multi-tap: 1–5 simultaneous fingers × 1–3 successive taps");
await act("tap", identifier("poc.gesture"), { position: { x: 0.25, y: 0.75 } });
await expectContent("poc.inputStatus", (item) => item.label === "Tap position: 0.25, 0.75");
const screenTargets = targets();
const surface = screenTargets.find(screen);
const gesture = screenTargets.find(identifier("poc.gesture"));
assert.ok(surface.actions.includes("tap"));
const x = (gesture.frame[0] + gesture.frame[2] * 0.75 - surface.frame[0]) / surface.frame[2];
const y = (gesture.frame[1] + gesture.frame[3] * 0.25 - surface.frame[1]) / surface.frame[3];
await act("tap", screen, { position: { x, y } });
await expectContent("poc.inputStatus", (item) => item.label === "Tap position: 0.75, 0.25");
console.log("PASS positioned tap: target-relative and screen-relative coordinates");
await act("input", identifier("poc.query"), { text: "테스트" });
await expectContent("poc.inputStatus", (item) => item.label === "Input: 테스트");
await act("input", identifier("poc.password"), { text: "necto-fixture-secret" });
assert.ok(!JSON.stringify(targets()).includes("necto-fixture-secret"));
assert.ok(!JSON.stringify(read()).includes("necto-fixture-secret"));
await act("tap", identifier("poc.push"));
assert.ok(!targets().some(identifier("poc.push")), "Detail must no longer offer Open detail");
await act("back", screen);
assert.ok(targets().some(identifier("poc.push")), "Back must restore the root screen");
await act("swipe", identifier("poc.scroll"), { direction: "up", distanceRatio: 0.7, durationMs: 500, position: { x: 0.25, y: 0.85 } });
await delay(1000);
assert.ok(!targets().some(identifier("poc.item.1")), "UIKit scroll should move Item 1 offscreen");
console.log("PASS UIKit: navigation bar, accessible gesture, input, secure value redaction, push/back, swipe");

await act("tap", label("Accessibility"));
await act("swipe", (target) => target.role === "scrollArea", { direction: "down", distanceRatio: 0.9, durationMs: 150 });
await delay(1500);
await act("tap", label("Open sheet"));
await expectContent("Accessibility Sheet", (item) => item.label === "Accessibility Sheet");
assert.ok(!targets().some(identifier("ax.tap")), "Covered background controls must not be offered");
assert.ok(!read().some(identifier("ax.tap")), "Covered background content must not be read");
console.log("PASS sheet: covered background is excluded from targets and content");
