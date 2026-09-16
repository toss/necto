//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

const cli = new URL("../bin/create-necto-plugin.js", import.meta.url);

function run(t, args) {
  const cwd = mkdtempSync(resolve(tmpdir(), "necto-generator-cli-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  return { cwd, ...spawnSync(process.execPath, [cli.pathname, ...args], {
    cwd, encoding: "utf8", timeout: 10_000,
  }) };
}

for (const type of ["device", "desktop"]) {
  for (const option of [["--type", type], [`--type=${type}`]]) {
    test(`creates ${type} with explicit ${option.join(" ")}`, (t) => {
      const result = run(t, ["Example", ...option]);
      assert.equal(result.status, 0, result.stderr);
      assert.ok(existsSync(resolve(result.cwd, "Example", "package.json")));
      assert.equal(existsSync(resolve(result.cwd, "Example", "Package.swift")), type === "device");
    });
  }
}

for (const option of [[], ["--type"], ["--type="], ["--type", "other"], ["--type", "DEVICE"]]) {
  test(`rejects missing or invalid type: ${JSON.stringify(option)}`, (t) => {
    const result = run(t, ["Example", ...option]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /device.*desktop/);
    assert.deepEqual(readdirSync(result.cwd), []);
  });
}
