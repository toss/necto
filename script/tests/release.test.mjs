//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

const version = "9.8.7";
const artifacts = [
  `Necto-${version}.dmg`,
  `Necto-${version}.dmg.sha256`,
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
      if (args[0] === "rev-parse") {
        if (args[1] === "HEAD") return console.log("fixture-head");
        if (process.env.NECTO_RELEASE_EXISTING_TAG) return console.log(process.env.NECTO_RELEASE_EXISTING_TAG);
        return process.exit(1);
      }
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

function runRelease(t, { flags = [], env = {}, expectedStatus = 0, externalScript = false, boringSSLRevision = "817ab07ebb53da35afea409ab9328f578492832d" } = {}) {
  const root = mkdtempSync(join(tmpdir(), "necto-release test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const path of ["script", "bin", "tmp", "Build/bin", "Build/Products/Necto.app/Contents/MacOS"]) {
    mkdirSync(join(root, path), { recursive: true });
  }
  copyFileSync(new URL("../release", import.meta.url), join(root, "script/release"));
  copyFileSync(new URL("../licenses.mjs", import.meta.url), join(root, "script/licenses.mjs"));
  mkdirSync(join(root, "script/licenses"));
  copyFileSync(new URL("../licenses/BoringSSL-817ab07.txt", import.meta.url), join(root, "script/licenses/BoringSSL-817ab07.txt"));
  copyFileSync(new URL("../../LICENSE", import.meta.url), join(root, "LICENSE"));
  mkdirSync(join(root, "LICENSES"));
  copyFileSync(new URL("../../LICENSES/PeerTalk.txt", import.meta.url), join(root, "LICENSES/PeerTalk.txt"));
  mkdirSync(join(root, "NectoMac/.build/checkouts/swift-argument-parser"), { recursive: true });
  writeFileSync(join(root, "NectoMac/.build/checkouts/swift-argument-parser/LICENSE.txt"), "fixture Swift license\n");
  for (const name of ["swift-nio", "swift-nio-ssl", "swift-atomics", "swift-collections", "swift-system"]) {
    const directory = join(root, "NectoMac/.build/checkouts", name);
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, "LICENSE.txt"), `fixture ${name} license\n`);
    if (["swift-nio", "swift-nio-ssl"].includes(name)) writeFileSync(join(directory, "NOTICE.txt"), `fixture ${name} notice\n`);
  }
  writeFileSync(join(root, "NectoMac/.build/checkouts/swift-nio-ssl/Package.swift"), `// BoringSSL Commit: ${boringSSLRevision}\n`);
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
  if (env.NECTO_RELEASE_FAIL_TOOL === "shasum") symlinkSync(tool, join(root, "bin/shasum"));
  for (const name of ["test", "pack-web-package.mjs"]) {
    symlinkSync(tool, join(root, "script", name));
  }
  let script = "script/release";
  if (externalScript) {
    mkdirSync(join(root, "tmp/runner"));
    script = join(root, "tmp/runner/release");
    copyFileSync(join(root, "script/release"), script);
  }
  const result = spawnSync("/bin/bash", [script, version, ...flags], {
    cwd: root,
    encoding: "utf8",
    timeout: 10_000,
    env: {
      PATH: `${join(root, "bin")}:${dirname(process.execPath)}:/usr/bin:/bin`,
      TMPDIR: join(root, "tmp"),
      NECTO_RELEASE_TEST_ROOT: root,
      ...(externalScript ? { NECTO_RELEASE_ROOT: root } : {}),
      ...env,
    },
  });
  assert.equal(result.status, expectedStatus, `${result.error ?? ""}\n${result.stdout}\n${result.stderr}`);
  return root;
}

function verifyArtifacts(root) {
  assert.equal(readFileSync(join(root, "Build/Products/Necto.app/Contents/Resources/NectoMac_necto-cli.bundle/Skills/necto/SKILL.md"), "utf8"), "fixture skill\n");
  const notices = readFileSync(join(root, "Build/Products/Necto.app/Contents/Resources/THIRD_PARTY_NOTICES.txt"), "utf8");
  const boringSSLLicense = readFileSync(new URL("../licenses/BoringSSL-817ab07.txt", import.meta.url), "utf8");
  for (const term of ["OpenSSL License", "Original SSLeay License", "ISC license", "fiat carries the MIT license"]) {
    assert.ok(boringSSLLicense.includes(term), `BoringSSL supplemental license must include ${term}`);
  }
  assert.ok(notices.includes(boringSSLLicense), "the app must contain the complete vendored BoringSSL license");
  for (const name of artifacts) assert.ok(readFileSync(join(root, "Build", name)).length > 0);
  const hash = createHash("sha256").update(readFileSync(join(root, "Build", artifacts[0]))).digest("hex");
  assert.equal(readFileSync(join(root, "Build", `${artifacts[0]}.sha256`), "utf8"), `${hash}  ${artifacts[0]}\n`);
  assert.equal(existsSync(join(root, "Build", `Necto-${version}-SHA256SUMS`)), false);
}

test("a dry run builds the app, checksum and web packages without publishing", (t) => {
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

test("a changed BoringSSL revision prevents publishing with stale license notices", (t) => {
  const root = runRelease(t, { boringSSLRevision: "different-revision", expectedStatus: 1 });
  assert.equal(readFileSync(join(root, "publications.jsonl"), "utf8"), "");
  assert.equal(existsSync(join(root, "Build", artifacts[0])), false);
});

test("a release publishes the tag and artifacts to the official repository", (t) => {
  const root = runRelease(t);
  verifyArtifacts(root);
  const calls = readFileSync(join(root, "publications.jsonl"), "utf8")
    .trim().split("\n").map((line) => JSON.parse(line));
  const release = calls.find(([name]) => name === "gh");
  assert.ok(release, "the release must be published");
  assert.deepEqual(calls.find(([name, action]) => name === "git" && action === "push"),
    ["git", "push", "https://github.com/toss/necto.git", version]);
  assert.equal(release[release.indexOf("--repo") + 1], "toss/necto");
  assert.ok(release.includes("--verify-tag"));
  assert.deepEqual(
    release.filter((argument) => argument.startsWith("Build/")).sort(),
    artifacts.map((name) => `Build/${name}`).sort(),
    "the release must include the DMG checksum used by API-free updates",
  );
});

test("a dry run can rebuild an existing tag only at its original commit", (t) => {
  const root = runRelease(t, {
    flags: ["--dry-run"], env: { NECTO_RELEASE_EXISTING_TAG: "fixture-head" }, externalScript: true,
  });
  verifyArtifacts(root);
  assert.equal(readFileSync(join(root, "publications.jsonl"), "utf8"), "");
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
  ["existing tag on another commit", { NECTO_RELEASE_EXISTING_TAG: "other" }, ["--dry-run"]],
  ["existing tag in local publish mode", { NECTO_RELEASE_EXISTING_TAG: "fixture-head" }],
  ["incorrect built version", { NECTO_RELEASE_BUILT_VERSION: "0.3.1" }],
  ["signing failure", { NECTO_RELEASE_FAIL_TOOL: "codesign" }],
  ["build failure", { NECTO_RELEASE_FAIL_TOOL: "xcodebuild" }],
  ["archive failure", { NECTO_RELEASE_FAIL_TOOL: "hdiutil" }],
  ["checksum failure", { NECTO_RELEASE_FAIL_TOOL: "shasum" }],
  ["unknown option", {}, ["--dryrun"]],
  ["extra arguments", {}, ["--dry-run", "unexpected"]],
]) {
  test(`${name} prevents publishing`, (t) => {
    const root = runRelease(t, { env, flags, expectedStatus: 1 });
    assert.equal(readFileSync(join(root, "publications.jsonl"), "utf8"), "");
  });
}
