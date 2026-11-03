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

function closure(name) {
  const visited = new Set();
  const pending = [name];
  while (pending.length) {
    const target = pending.pop();
    if (visited.has(target)) continue;
    visited.add(target);
    pending.push(...dependencies(target));
  }
  return visited;
}

const plugins = ["NectoNetworkPlugin", "NectoEventsPlugin", "NectoFilesPlugin",
  "NectoPreferencesPlugin", "NectoPerformancePlugin", "NectoUIControlPlugin"];

test("every plugin is independently selectable without sibling plugins", () => {
  for (const name of plugins) {
    assert.deepEqual(manifest.products.find(product => product.name === name)?.targets, [name]);
    const included = closure(name);
    for (const other of plugins.filter(other => other !== name)) assert.ok(!included.has(other));
    assert.ok(!included.has("NectoURLSessionCapturePlugin"));
    assert.ok(!included.has("NectoProcessMetricPlugin"));
  }
});

test("the core SDK and public reporting products exclude private runtime modules", () => {
  assert.deepEqual(manifest.products.find(product => product.name === "NectoSDK").targets, ["NectoSDK"]);
  for (const name of ["NectoSDK", "NectoNetworkPlugin"]) {
    const included = closure(name);
    for (const excluded of ["NectoURLSessionCapturePlugin", "NectoUIControlPlugin"]) {
      assert.ok(!included.has(excluded), `${name} must not link ${excluded}`);
    }
  }
  assert.deepEqual(dependencies("NectoURLSessionCapturePlugin").sort(), ["NectoModel", "NectoNetworkPlugin", "NectoSDK"]);
  assert.deepEqual(dependencies("NectoProcessMetricPlugin").sort(), ["NectoModel", "NectoPerformancePlugin", "NectoSDK"]);
});
