//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

const version = "9.8.7";
const artifacts = [
  `Necto-${version}.dmg`,
  `necto-bridge-${version}.tgz`,
  `create-necto-plugin-${version}.tgz`,
];

// Run the real release script, but never build, sign, tag, push or contact GitHub.
// Version, signing and publication ordering are tested with stubs.
function fakeTool() {
  const fs = require("node:fs");
  const { basename, join } = require("node:path");
  const root = process.env.NECTO_RELEASE_TEST_ROOT;
  const name = basename(process.argv[1]);
  const args = process.argv.slice(2);
  const record = () => fs.appendFileSync(join(root, "publications.jsonl"), JSON.stringify([name, ...args]) + "\n");
  fs.appendFileSync(join(root, "commands.jsonl"), JSON.stringify([name, ...args]) + "\n");
  if (name === process.env.NECTO_RELEASE_FAIL_TOOL) return process.exit(1);
  switch (name) {
    case "git":
      if (args[0] === "status") return;
      if (args[0] === "branch") return console.log("main");
      if (args[0] === "rev-parse") return process.exit(1);
      if (["tag", "push"].includes(args[0])) return record();
      break;
    case "gh":
      if (args[0] === "release" && args[1] === "create") return record();
      break;
    case "xcodebuild":
      if (!args.includes("MARKETING_VERSION=9.8.7")) throw new Error("Missing release version override");
      fs.appendFileSync(join(root, "xcodebuild.jsonl"), JSON.stringify(args) + "\n");
      return console.log(args.includes("-showBuildSettings")
        ? `    TARGET_BUILD_DIR = ${join(root, "Build", "Products")}`
        : "BUILD fixture (no app was built)");
    case "swift":
      if (args.includes("--show-bin-path")) console.log(join(root, "Build", "bin"));
      return;
    case "codesign":
    case "yarn":
    case "test":
      return;
    case "plutil":
      return console.log(process.env.NECTO_RELEASE_BUILT_VERSION ?? "9.8.7");
    case "xcrun":
      throw new Error("Releasing must not require notarization");
    case "hdiutil":
      return fs.writeFileSync(args.at(-1), "fixture disk image\n");
    case "pack-web-package.mjs": {
      const prefix = args[0] === "WebPackages/Bridge" ? "necto-bridge" : "create-necto-plugin";
      return fs.writeFileSync(join(args[2], `${prefix}-${args[1]}.tgz`), `fixture ${prefix}\n`);
    }
  }
  throw new Error(`Unexpected release command: ${name} ${args.join(" ")}`);
}

function runRelease(t, { flags = [], env = {}, expectedStatus = 0 } = {}) {
  const root = mkdtempSync(join(tmpdir(), "necto-release test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const path of ["script", "bin", "tmp", "Build/bin", "Build/Products/Necto.app/Contents/MacOS"]) {
    mkdirSync(join(root, path), { recursive: true });
  }
  copyFileSync(new URL("../release", import.meta.url), join(root, "script/release"));
  copyFileSync(new URL("../licenses.mjs", import.meta.url), join(root, "script/licenses.mjs"));
  copyFileSync(new URL("../../LICENSE", import.meta.url), join(root, "LICENSE"));
  mkdirSync(join(root, "LICENSES"));
  copyFileSync(new URL("../../LICENSES/PeerTalk.txt", import.meta.url), join(root, "LICENSES/PeerTalk.txt"));
  mkdirSync(join(root, "NectoMac/.build/checkouts/swift-argument-parser"), { recursive: true });
  writeFileSync(join(root, "NectoMac/.build/checkouts/swift-argument-parser/LICENSE.txt"), "fixture Swift license\n");
  mkdirSync(join(root, "node_modules/vite"), { recursive: true });
  writeFileSync(join(root, "node_modules/vite/package.json"), JSON.stringify({ name: "vite", version: "1.0.0" }));
  writeFileSync(join(root, "node_modules/vite/LICENSE.md"), "fixture Vite license\n");
  writeFileSync(join(root, "Build/bin/necto-cli"), "fixture CLI\n");
  mkdirSync(join(root, "Build/bin/NectoMac_necto-cli.bundle/Skills/necto"), { recursive: true });
  writeFileSync(join(root, "Build/bin/NectoMac_necto-cli.bundle/Skills/necto/SKILL.md"), "fixture skill\n");
  writeFileSync(join(root, "publications.jsonl"), "");
  writeFileSync(join(root, "commands.jsonl"), "");
  writeFileSync(join(root, "xcodebuild.jsonl"), "");
  const tool = join(root, "fake-tool.cjs");
  writeFileSync(tool, `#!/usr/bin/env node\n(${fakeTool.toString()})();\n`, { mode: 0o755 });
  for (const name of ["git", "gh", "xcodebuild", "swift", "codesign", "yarn", "hdiutil", "plutil", "xcrun"]) {
    symlinkSync(tool, join(root, "bin", name));
  }
  for (const name of ["test", "pack-web-package.mjs"]) {
    symlinkSync(tool, join(root, "script", name));
  }
  const result = spawnSync("/bin/bash", ["script/release", version, ...flags], {
    cwd: root,
    encoding: "utf8",
    timeout: 10_000,
    env: {
      PATH: `${join(root, "bin")}:${dirname(process.execPath)}:/usr/bin:/bin`,
      TMPDIR: join(root, "tmp"),
      NECTO_RELEASE_TEST_ROOT: root,
      ...env,
    },
  });
  assert.equal(result.status, expectedStatus, `${result.error ?? ""}\n${result.stdout}\n${result.stderr}`);
  return root;
}

function verifyArtifacts(root) {
  assert.equal(readFileSync(join(root, "Build/Products/Necto.app/Contents/Resources/NectoMac_necto-cli.bundle/Skills/necto/SKILL.md"), "utf8"), "fixture skill\n");
  for (const name of artifacts) assert.ok(readFileSync(join(root, "Build", name)).length > 0);
  assert.equal(existsSync(join(root, "Build", `${artifacts[0]}.sha256`)), false);
  assert.equal(existsSync(join(root, "Build", `Necto-${version}-SHA256SUMS`)), false);
}

test("a dry run builds the app and web packages without checksum sidecars or publishing", (t) => {
  const root = runRelease(t, { flags: ["--dry-run"] });
  verifyArtifacts(root);
  assert.equal(readFileSync(join(root, "publications.jsonl"), "utf8"), "");
  const calls = readFileSync(join(root, "commands.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  assert.ok(!calls.some(([name]) => name === "xcrun"));
  assert.ok(calls.filter(([name, ...args]) => name === "codesign" && args.includes("--sign"))
    .every((args) => args[args.indexOf("--sign") + 1] === "-"));
  const builds = readFileSync(join(root, "xcodebuild.jsonl"), "utf8")
    .trim().split("\n").map((line) => JSON.parse(line));
  assert.ok(builds.length >= 2, "release build and settings lookup must both run");
  assert.ok(
    builds.every((arguments_) => arguments_.includes(`MARKETING_VERSION=${version}`)),
    "every Xcode invocation must use the version being released",
  );
});

test("a release attaches only the app and web packages", (t) => {
  const root = runRelease(t);
  verifyArtifacts(root);
  const calls = readFileSync(join(root, "publications.jsonl"), "utf8")
    .trim().split("\n").map((line) => JSON.parse(line));
  const release = calls.find(([name]) => name === "gh");
  assert.ok(release, "the release must be published");
  assert.deepEqual(
    release.filter((argument) => argument.startsWith("Build/")).sort(),
    artifacts.map((name) => `Build/${name}`).sort(),
    "GitHub provides asset digests; no separate checksum files should be attached",
  );
});

test("publishing ad-hoc signs and verifies the embedded CLI and app without credentials", (t) => {
  const root = runRelease(t);
  const calls = readFileSync(join(root, "commands.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  const sign = calls.filter(([name, ...args]) => name === "codesign" && args.includes("--sign"));
  assert.equal(sign.length, 2);
  assert.ok(sign[0].at(-1).endsWith("Contents/MacOS/necto-cli"));
  assert.ok(sign[1].at(-1).endsWith("Necto.app"));
  for (const args of sign) {
    assert.equal(args[args.indexOf("--sign") + 1], "-");
    assert.ok(args.includes("--timestamp=none"));
  }
  const verify = calls.findIndex(([name, ...args]) => name === "codesign" && args.includes("--deep"));
  const archive = calls.findIndex(([name]) => name === "hdiutil");
  const tag = calls.findIndex(([name, action]) => name === "git" && action === "tag");
  assert.ok(verify > calls.indexOf(sign[1]) && archive > verify && tag > archive);
  assert.ok(!calls.some(([name]) => name === "xcrun"));
});

for (const [name, env, flags] of [
  ["incorrect built version", { NECTO_RELEASE_BUILT_VERSION: "0.3.1" }],
  ["signing failure", { NECTO_RELEASE_FAIL_TOOL: "codesign" }],
  ["build failure", { NECTO_RELEASE_FAIL_TOOL: "xcodebuild" }],
  ["archive failure", { NECTO_RELEASE_FAIL_TOOL: "hdiutil" }],
  ["unknown option", {}, ["--dryrun"]],
  ["extra arguments", {}, ["--dry-run", "unexpected"]],
]) {
  test(`${name} prevents publishing`, (t) => {
    const root = runRelease(t, { env, flags, expectedStatus: 1 });
    assert.equal(readFileSync(join(root, "publications.jsonl"), "utf8"), "");
  });
}
