//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { execFileSync, execSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

test("the packed generator creates projects that ignore generated files", async (t) => {
  const directory = await mkdtemp(resolve(tmpdir(), "necto-packed-generator-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const [{ filename }] = JSON.parse(execSync("npm pack --ignore-scripts --json", {
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    encoding: "utf8",
    env: {
      ...process.env,
      npm_config_pack_destination: directory,
      npm_config_cache: resolve(directory, "cache"),
    },
  }));
  execFileSync("tar", ["-xzf", resolve(directory, filename), "-C", directory]);
  const { createProject } = await import(pathToFileURL(resolve(directory, "package/src/create-project.js")).href);

  for (const type of ["device", "desktop"]) {
    await t.test(type, async () => {
      const project = await createProject({ name: "HostStatus", type, cwd: resolve(directory, type) });
      const ignore = await readFile(resolve(project.directory, ".gitignore"), "utf8");
      assert.doesNotMatch(ignore, /__[A-Z_]+__/);
      await assert.rejects(readFile(resolve(project.directory, "gitignore")), { code: "ENOENT" });
      const paths = type === "desktop"
        ? ["node_modules/example/index.js", "dist/index.html"]
        : [
          "node_modules/example/index.js", ".build/debug/example", "DerivedData/example", "Package.resolved",
          "Sources/HostStatusPlugin/Panel/assets/main.js",
          "Sources/HostStatusPlugin/Panel/index.html",
          "Sources/HostStatusPlugin/Panel/manifest.json",
        ];
      execFileSync("git", ["init", "--quiet"], { cwd: project.directory });
      const ignored = execFileSync("git", ["-c", "core.excludesFile=", "check-ignore", "--no-index", "--stdin"], {
        cwd: project.directory,
        input: `${paths.join("\n")}\npackage.json\nsrc/main.ts\nSources/HostStatusPlugin/HostStatusPlugin.swift\n`,
        encoding: "utf8",
      });
      assert.deepEqual(ignored.trim().split(/\r?\n/), paths);
    });
  }
});
