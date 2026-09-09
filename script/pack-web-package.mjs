#!/usr/bin/env node
//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const [sourceArgument, version, destinationArgument] = process.argv.slice(2);
if (!sourceArgument || !/^\d+\.\d+\.\d+$/.test(version ?? "") || !destinationArgument) {
  console.error("Usage: script/pack-web-package.mjs <package-directory> <version> <destination-directory>");
  process.exit(1);
}

const source = resolve(sourceArgument);
const destination = resolve(destinationArgument);
const temporaryRoot = await mkdtemp(resolve(tmpdir(), "necto-web-package-"));
const staged = resolve(temporaryRoot, "package");

try {
  await mkdir(destination, { recursive: true });
  await cp(source, staged, {
    recursive: true,
    filter: (path) => basename(path) !== "node_modules",
  });
  await cp(new URL("../LICENSE", import.meta.url), resolve(staged, "LICENSE"));

  const manifestPath = resolve(staged, "package.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.version = version;
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  const packed = spawnSync("npm", [
    "pack",
    staged,
    "--pack-destination",
    destination,
    "--ignore-scripts",
    "--json",
  ], {
    encoding: "utf8",
  });
  if (packed.status !== 0) {
    throw new Error(packed.stderr.trim() || "npm pack failed");
  }

  const [{ filename }] = JSON.parse(packed.stdout);
  console.log(resolve(destination, filename));
} finally {
  await rm(temporaryRoot, { recursive: true, force: true });
}
