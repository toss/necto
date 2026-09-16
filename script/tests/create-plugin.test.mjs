//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const script = resolve(import.meta.dirname, "../create-plugin");

function fixture(t, env = {}) {
  const directory = mkdtempSync(join(tmpdir(), "necto-create-plugin-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const capture = join(directory, "arguments.json");
  writeFileSync(join(directory, "curl"), '#!/bin/sh\n[ "$LOOKUP_STATUS" = 0 ] || exit "$LOOKUP_STATUS"\nprintf %s "$RELEASE_URL"\n', { mode: 0o755 });
  writeFileSync(join(directory, "npx"), `#!${process.execPath}\nrequire("node:fs").writeFileSync(process.env.CAPTURE, JSON.stringify({ args: process.argv.slice(2), cwd: process.cwd() }));\nprocess.exit(Number(process.env.GENERATOR_STATUS));\n`, { mode: 0o755 });
  return {
    directory,
    capture,
    run: (args) => spawnSync("/bin/bash", ["-s", "--", ...args], {
      input: readFileSync(script, "utf8"), cwd: directory, encoding: "utf8",
      env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, CAPTURE: capture,
        RELEASE_URL: "https://github.com/toss/necto/releases/tag/9.8.7",
        LOOKUP_STATUS: "0", GENERATOR_STATUS: "0", ...env },
    }),
  };
}

test("resolves the latest release and preserves generator arguments and working directory", (t) => {
  const f = fixture(t);
  const args = ["My Plugin", "--type", "desktop"];
  const result = f.run(args);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(readFileSync(f.capture, "utf8")), {
    args: ["--yes", "--package=https://github.com/toss/necto/releases/download/9.8.7/create-necto-plugin-9.8.7.tgz", "create-necto-plugin", ...args],
    cwd: realpathSync(f.directory),
  });
});

for (const [name, env, status] of [
  ["failed lookup", { LOOKUP_STATUS: "22" }, 22],
  ["unexpected redirect", { RELEASE_URL: "https://github.com/login" }, 1],
  ["unsupported version", { RELEASE_URL: "https://github.com/toss/necto/releases/tag/invalid" }, 1],
]) {
  test(`${name} stops before running the generator`, (t) => {
    const f = fixture(t, env);
    assert.equal(f.run(["Uptime", "--type", "device"]).status, status);
    assert.equal(existsSync(f.capture), false);
  });
}

test("propagates generator failure", (t) => {
  const f = fixture(t, { GENERATOR_STATUS: "7" });
  assert.equal(f.run(["Uptime", "--type", "device"]).status, 7);
});

test("help and missing arguments do not need a release lookup", (t) => {
  const f = fixture(t, { LOOKUP_STATUS: "22" });
  assert.equal(f.run(["--help"]).status, 0);
  assert.equal(f.run([]).status, 2);
  assert.equal(existsSync(f.capture), false);
});

for (const option of [[], ["--type"], ["--type="], ["--type", "other"], ["--type", "DEVICE"]]) {
  test(`rejects missing or invalid type before lookup: ${JSON.stringify(option)}`, (t) => {
    const f = fixture(t, { LOOKUP_STATUS: "22" });
    const result = f.run(["Example", ...option]);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /--type device or --type desktop/);
    assert.equal(existsSync(f.capture), false);
  });
}

test("accepts an explicit type with equals syntax", (t) => {
  const f = fixture(t);
  assert.equal(f.run(["Example", "--type=device"]).status, 0);
  assert.ok(existsSync(f.capture));
});
