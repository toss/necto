//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { docsLicensePlugin, packageNotice } from "../licenses.mjs";

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "necto-license test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

async function dependency(root, name, files) {
  const directory = join(root, "node_modules", name);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "package.json"), JSON.stringify({ name, version: "1.2.3" }));
  for (const [name, text] of Object.entries(files)) await writeFile(join(directory, name), text);
  return directory;
}

test("notices preserve complete license and upstream NOTICE text", async (t) => {
  const root = await fixture(t);
  const directory = await dependency(root, "example", { "LICENSE.txt": "full license\nexception\n", NOTICE: "attribution\n" });
  assert.equal(await packageNotice(directory), "example 1.2.3\n\nLICENSE.txt\n\nfull license\nexception\n\n\nNOTICE\n\nattribution\n");
});

test("a missing license fails instead of silently omitting a dependency", async (t) => {
  const root = await fixture(t);
  const directory = await dependency(root, "unlicensed", { NOTICE: "not a license" });
  await assert.rejects(packageNotice(directory), /Missing license for unlicensed/);
});

test("the supplemental DocSearch license is limited to the reviewed version", async (t) => {
  const root = await fixture(t);
  const directory = await dependency(root, "@docsearch/css", {});
  await writeFile(join(directory, "package.json"), JSON.stringify({ name: "@docsearch/css", version: "3.8.2" }));
  assert.match(await packageNotice(directory), /Copyright \(c\) 2015-present Algolia, Inc\./);
  await writeFile(join(directory, "package.json"), JSON.stringify({ name: "@docsearch/css", version: "3.8.3" }));
  await assert.rejects(packageNotice(directory), /Missing license/);
});

test("docs builds fail when an emitted dependency has no license", async (t) => {
  const root = await fixture(t);
  const directory = await dependency(root, "unlicensed", {});
  const plugin = docsLicensePlugin();
  plugin.configResolved({ build: { ssr: false } });
  await assert.rejects(plugin.generateBundle.call({ emitFile() { assert.fail("Do not emit incomplete notices"); } }, {}, {
    "client.js": { type: "chunk", modules: { [join(directory, "index.js")]: {} } },
  }), /Missing license for unlicensed/);
});

test("docs notices include emitted dependencies, fonts and the virtual Vite polyfill", async (t) => {
  const root = await fixture(t);
  const directory = await dependency(root, "@example/client", { LICENSE: "client license" });
  await dependency(root, "build-only", { LICENSE: "not shipped" });
  await mkdir(join(directory, "dist"));
  await writeFile(join(directory, "dist/package.json"), '{"type":"module"}');
  const plugin = docsLicensePlugin();
  plugin.configResolved({ build: { ssr: false } });
  const output = [];
  const context = { emitFile: (asset) => output.push(asset) };
  const bundle = { "client.js": { type: "chunk", modules: {
    [join(directory, "dist/index.js")]: {},
    [join(directory, "dist/other.js?commonjs-proxy")]: {},
    "\0vite/modulepreload-polyfill.js": {},
  } } };
  await plugin.generateBundle.call(context, {}, bundle);
  assert.equal(output.length, 1);
  assert.equal(output[0].fileName, "THIRD_PARTY_NOTICES.txt");
  const { source } = output[0];
  assert.equal(source.split("@example/client 1.2.3").length, 2);
  assert.match(source, /Viva Republica/);
  assert.match(source, /vite \d/);
  assert.match(source, /SIL OPEN FONT LICENSE Version 1.1/);
  assert.doesNotMatch(source, /not shipped/);
  plugin.configResolved({ build: { ssr: true } });
  await plugin.generateBundle.call(context, {}, bundle);
  assert.equal(output.length, 1, "SSR must not overwrite client notices");
});

test("npm packaging includes Necto's full license even with a restrictive files list", async (t) => {
  const root = await fixture(t);
  const source = join(root, "source");
  await mkdir(source);
  await writeFile(join(source, "package.json"), JSON.stringify({ name: "necto-license-fixture", version: "0.0.0", files: ["index.js"] }));
  await writeFile(join(source, "index.js"), "export {};\n");
  const packed = spawnSync(process.execPath, [fileURLToPath(new URL("../pack-web-package.mjs", import.meta.url)), source, "1.2.3", root], { encoding: "utf8", timeout: 30_000 });
  assert.equal(packed.status, 0, packed.stderr);
  const license = spawnSync("tar", ["-xOf", packed.stdout.trim(), "package/LICENSE"], { encoding: "utf8" });
  assert.equal(license.status, 0, license.stderr);
  assert.equal(license.stdout, await readFile(new URL("../../LICENSE", import.meta.url), "utf8"));
  assert.equal(JSON.parse(await readFile(join(source, "package.json"), "utf8")).version, "0.0.0");
});
