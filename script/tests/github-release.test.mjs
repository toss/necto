//
// Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { release } from "../github-release.mjs";

const head = "a".repeat(40);
const older = "b".repeat(40);
const version = "0.1.0";
const root = "repos/toss/necto/";
const download = "[**Download Necto**](https://github.com/toss/necto/releases/download/0.1.0/Necto-0.1.0.dmg)";
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

function fixture(t, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), "necto-github-release-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const names = [`Necto-${version}.dmg`, `Necto-${version}.dmg.sha256`, `necto-bridge-${version}.tgz`, `create-necto-plugin-${version}.tgz`];
  names.forEach((name) => writeFileSync(join(directory, name), name));
  writeFileSync(join(directory, names[1]), `${hash(readFileSync(join(directory, names[0])))}  ${names[0]}\n`);
  const state = { tag: options.tag ?? null, draft: options.draft, assets: options.assets ?? [], calls: [], uploads: 0 };
  const ok = (value = "") => ({ status: 0, stdout: typeof value === "string" ? value : JSON.stringify(value), stderr: "" });
  const fail = (message) => ({ status: 1, stdout: "", stderr: message });
  const run = (tool, args, input) => {
    state.calls.push([tool, args, input]);
    if (tool === "git") {
      if (args[0] === "merge-base") return options.unrelated ? fail("not an ancestor") : ok();
      if (args[1] === "HEAD") return ok(head);
      if (args[2] === `refs/tags/${version}^{commit}`) return options.tag ? ok(options.tag) : fail("no local tag");
      if (args[2]?.endsWith("^{commit}")) return ok(options.draftCommit ?? head);
    }
    if (tool === "gh" && args[0] === "release") {
      assert.equal(args[1], "upload");
      state.uploads++;
      if (options.uploadFailure) return fail("upload interrupted");
      for (const path of args.slice(3, -2)) {
        const data = readFileSync(path);
        state.assets.push({ name: path.split("/").at(-1), size: data.length, digest: `sha256:${hash(data)}`, state: "uploaded" });
      }
      if (options.corruptUpload) state.assets[0].digest = "sha256:corrupted";
      return ok();
    }
    if (tool === "gh" && args[0] === "api") {
      const path = args[1].slice(root.length);
      const method = args[args.indexOf("--method") + 1];
      const body = input ? JSON.parse(input) : undefined;
      if (path === "releases?per_page=100") return ok([state.draft ? [state.draft] : []]);
      if (path.startsWith("actions/workflows/check.yml/runs?")) {
        const target = new URLSearchParams(path.split("?")[1]).get("head_sha");
        return ok({ workflow_runs: options.noCI ? [] : [{ head_sha: target, head_branch: "main", status: "completed", conclusion: options.failedCI ? "failure" : "success" }] });
      }
      if (path === `git/ref/tags/${version}`) {
        return state.tag ? ok({ object: { type: "commit", sha: options.changedTag && state.uploads ? older : state.tag } }) : fail("gh: Not Found (HTTP 404)");
      }
      if (path === "git/refs") { state.tag = body.sha; return ok({ object: { type: "commit", sha: body.sha } }); }
      if (path === "releases") { state.draft = { id: 7, body: "Generated release notes", ...body }; return ok(state.draft); }
      if (path === "releases/7/assets?per_page=100") return ok(state.assets);
      if (path === "releases/7" && method === "PATCH") {
        Object.assign(state.draft, body, { html_url: "https://github.com/toss/necto/releases/tag/0.1.0" });
        return ok(state.draft);
      }
      if (path === "releases/7") return ok(state.draft);
    }
    throw new Error(`Unexpected call: ${tool} ${args.join(" ")}`);
  };
  return { state, directory, run, names };
}

const draft = { id: 7, tag_name: version, target_commitish: head, draft: true };

test("preparation selects main or an existing tag without mutating GitHub", (t) => {
  for (const tag of [null, older]) {
    const f = fixture(t, { tag, draft: { ...draft } });
    assert.equal(release("prepare", version, undefined, f), tag ?? head);
    assert.ok(f.state.calls.every(([tool, args]) => tool !== "gh" || !["POST", "PATCH"].some((method) => args.includes(method))));
  }
});

test("publishing creates a tag and draft, verifies all four uploads, then publishes", (t) => {
  const f = fixture(t);
  assert.equal(release("publish", version, head, f), "https://github.com/toss/necto/releases/tag/0.1.0");
  assert.equal(f.state.tag, head);
  assert.equal(f.state.draft.draft, false);
  assert.equal(f.state.draft.body, `${download}\n\nGenerated release notes`);
  assert.deepEqual(f.state.assets.map((item) => item.name), f.names);
  assert.equal(f.state.calls.at(-1)[1].at(-3), "PATCH");
});

test("an existing tag and draft resume without recreating either", (t) => {
  const f = fixture(t, { tag: older, draft: { ...draft, target_commitish: older, body: "Existing release notes" } });
  release("publish", version, older, f);
  assert.equal(f.state.tag, older);
  assert.equal(f.state.draft.body, `${download}\n\nExisting release notes`);
  assert.ok(!f.state.calls.some(([, args]) => args.includes("POST")));
});

test("identical draft assets are reused on retry", (t) => {
  const f = fixture(t, { tag: head, draft: { ...draft, body: `${download}\n\nExisting release notes` } });
  const data = readFileSync(join(f.directory, f.names[0]));
  f.state.assets.push({ name: f.names[0], size: data.length, digest: `sha256:${hash(data)}`, state: "uploaded" });
  release("publish", version, head, f);
  const upload = f.state.calls.find(([, args]) => args[0] === "release")[1];
  assert.ok(!upload.includes(join(f.directory, f.names[0])));
  assert.equal(f.state.assets.length, 4);
  assert.equal(f.state.draft.body, `${download}\n\nExisting release notes`);
});

for (const [name, options, error] of [
  ["published version", { draft: { ...draft, draft: false } }, /already published/],
  ["failed main CI", { failedCI: true }, /must succeed/],
  ["missing main CI", { noCI: true }, /must succeed/],
  ["tag on another commit", { tag: older }, /does not point/],
  ["commit outside main", { unrelated: true }, /not an ancestor/],
  ["draft targeting another commit", { draft: { ...draft }, draftCommit: older }, /different commit/],
  ["conflicting draft asset", { draft: { ...draft }, assets: [{ name: "unexpected" }] }, /conflicts/],
]) {
  test(`${name} prevents all publication writes`, (t) => {
    const f = fixture(t, options);
    assert.throws(() => release("publish", version, head, f), error);
    assert.ok(f.state.calls.every(([, args]) => !args.includes("POST") && !args.includes("PATCH") && args[0] !== "release"));
  });
}

for (const [name, options, error] of [
  ["upload failure", { uploadFailure: true }, /interrupted/],
  ["corrupted upload", { corruptUpload: true }, /verification/],
  ["tag changed during upload", { changedTag: true }, /tag changed/],
]) {
  test(`${name} leaves the release unpublished`, (t) => {
    const f = fixture(t, options);
    assert.throws(() => release("publish", version, head, f), error);
    assert.equal(f.state.draft.draft, true);
  });
}

test("invalid version and corrupt checksum fail before any writes", (t) => {
  const f = fixture(t);
  assert.throws(() => release("prepare", "0.1.0; echo unsafe", undefined, f), /Usage/);
  assert.equal(f.state.calls.length, 0);
  writeFileSync(join(f.directory, f.names[1]), "wrong hash");
  assert.throws(() => release("publish", version, head, f), /checksum/);
  assert.ok(!f.state.calls.some(([, args]) => args.includes("POST")));
});
