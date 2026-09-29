//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(import.meta.dirname, "../..");
const manifest = JSON.parse(execFileSync("swift", ["package", "dump-package"], {
  cwd: root, encoding: "utf8", timeout: 60_000,
}));

function dependencies(name) {
  const target = manifest.targets.find(target => target.name === name);
  assert.ok(target, `Missing target: ${name}`);
  return target.dependencies.map(dependency => {
    const reference = dependency.byName ?? dependency.target ?? dependency.product;
    assert.ok(reference, `Unknown dependency of ${name}: ${JSON.stringify(dependency)}`);
    return reference[0];
  });
}

test("the SDK bridge depends only on model and transport", () => {
  assert.deepEqual(dependencies("NectoSDK").sort(), ["NectoModel", "NectoTransport"]);
});

test("default plugin interfaces do not pull in capture implementations", () => {
  const visited = new Set();
  const pending = ["NectoDefaultPlugins"];
  while (pending.length) {
    const name = pending.pop();
    if (visited.has(name)) continue;
    visited.add(name);
    pending.push(...dependencies(name).filter(dependency =>
      manifest.targets.some(target => target.name === dependency)));
  }
  for (const capture of ["NectoURLSessionCapture", "NectoProcessMetrics"]) {
    assert.ok(!visited.has(capture), `${capture} must remain an opt-in implementation`);
  }
});
