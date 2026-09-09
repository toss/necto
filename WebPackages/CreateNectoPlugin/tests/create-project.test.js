//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import { createProject } from "../src/create-project.js";

test("creates a device plugin with an ExampleApp and Xcode project", async () => {
  const cwd = await mkdtemp(resolve(tmpdir(), "create-necto-device-"));
  const result = await createProject({
    name: "Uptime",
    type: "device",
    cwd,
    bridgeSpec: "file:../necto-bridge.tgz",
    nectoVersion: "9.8.7",
  });

  assert.equal(result.pluginModule, "UptimePlugin");
  assert.equal(result.pluginID, "com.example.uptime");
  const manifest = JSON.parse(await readFile(resolve(cwd, "Uptime", "panel", "public", "manifest.json"), "utf8"));
  assert.equal(manifest.id, result.pluginID);
  assert.equal(manifest.name, "Uptime");
  assert.match(await readFile(resolve(cwd, "Uptime", "Sources", "UptimePlugin", "UptimePlugin.swift"), "utf8"), /let id = "com\.example\.uptime"/);
  assert.match(await readFile(resolve(cwd, "Uptime", "Package.swift"), "utf8"), /exact: "9\.8\.7"/);
  assert.match(await readFile(resolve(cwd, "Uptime", "Uptime.xcodeproj", "project.pbxproj"), "utf8"), /UptimePlugin/);
  assert.match(await readFile(resolve(cwd, "Uptime", "ExampleApp", "ExampleApp.swift"), "utf8"), /NectoSDK\.register\(UptimePlugin\(\)\)/);
  assert.equal(await containsTemplateToken(resolve(cwd, "Uptime", "Package.swift")), false);
});

test("creates a desktop plugin without Swift or Xcode", async () => {
  const cwd = await mkdtemp(resolve(tmpdir(), "create-necto-desktop-"));
  await createProject({
    name: "host-status",
    type: "desktop",
    cwd,
    bridgeSpec: "file:../necto-bridge.tgz",
    nectoVersion: "9.8.7",
  });

  const manifest = JSON.parse(await readFile(resolve(cwd, "host-status", "public", "manifest.json"), "utf8"));
  assert.equal(manifest.id, "com.example.host-status");
  await assert.rejects(readFile(resolve(cwd, "host-status", "Package.swift"), "utf8"), /ENOENT/);
});

// Publishing is the step the scaffold used to leave to a guess. The workflow is the
// answer, so it has to arrive with the project and with its placeholders filled in —
// a template that silently stops being copied would put the guess back.
test("a desktop plugin arrives able to publish itself", async () => {
  const cwd = await mkdtemp(resolve(tmpdir(), "create-necto-release-"));
  await createProject({
    name: "host-status",
    type: "desktop",
    cwd,
    bridgeSpec: "file:../necto-bridge.tgz",
    nectoVersion: "9.8.7",
  });

  const workflow = await readFile(
    resolve(cwd, "host-status", ".github", "workflows", "release.yml"),
    "utf8",
  );

  assert.doesNotMatch(workflow, /__[A-Z_]+__/, "placeholders were left unreplaced");
  assert.match(workflow, /HostStatus-\$VERSION\.zip/);
  assert.match(workflow, /^permissions:\n  contents: write$/m);
  assert.match(workflow, /jq -r \.version dist\/manifest\.json/);
});

test("does not write into a non-empty directory", async () => {
  const cwd = await mkdtemp(resolve(tmpdir(), "create-necto-existing-"));
  await mkdir(resolve(cwd, "Existing"));
  await writeFile(resolve(cwd, "Existing", "keep.txt"), "keep");

  await assert.rejects(
    createProject({ name: "Existing", type: "desktop", cwd }),
    /Directory is not empty/,
  );
});

async function containsTemplateToken(path) {
  return /__[A-Z_]+__/.test(await readFile(path, "utf8"));
}
