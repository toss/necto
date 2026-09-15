//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repository = "toss/necto";
const apiRoot = `repos/${repository}`;
const digest = (data) => `sha256:${createHash("sha256").update(data).digest("hex")}`;

export function release(mode, version, commit, {
  run = (tool, args, input) => spawnSync(tool, args, { input, encoding: "utf8", timeout: 120_000 }),
  directory = "Build",
} = {}) {
  if (!["prepare", "publish"].includes(mode) || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version ?? "")) {
    throw new Error("Usage: github-release.mjs prepare <version> | publish <version> <commit>");
  }
  const command = (tool, args, input) => {
    const result = run(tool, args, input);
    if (result.status !== 0) throw new Error(result.stderr || result.error?.message || `${tool} failed`);
    return result.stdout.trim();
  };
  const api = (path, body, { method = body ? "POST" : "GET", missing = false } = {}) => {
    const args = ["api", `${apiRoot}/${path}`, "--method", method];
    if (body) args.push("--input", "-");
    const result = run("gh", args, body ? JSON.stringify(body) : undefined);
    if (result.status !== 0) {
      if (missing && /HTTP 404/.test(result.stderr)) return null;
      throw new Error(result.stderr || result.error?.message || "GitHub request failed");
    }
    return result.stdout.trim() ? JSON.parse(result.stdout) : null;
  };
  const drafts = JSON.parse(command("gh", ["api", `${apiRoot}/releases?per_page=100`, "--paginate", "--slurp"]))
    .flat().filter((item) => item.tag_name === version);
  if (drafts.length > 1 || drafts.some((item) => !item.draft)) {
    throw new Error(`Release ${version} is already published or ambiguous.`);
  }
  let draft = drafts[0];
  const head = command("git", ["rev-parse", "HEAD"]);
  const localTag = run("git", ["rev-parse", "--verify", `refs/tags/${version}^{commit}`]);
  const target = mode === "prepare" ? (localTag.status === 0 ? localTag.stdout.trim() : head) : commit;
  if (!/^[a-f0-9]{40}$/.test(target ?? "")) throw new Error("A full release commit is required.");
  command("git", ["merge-base", "--is-ancestor", target, head]);

  const runs = api(`actions/workflows/check.yml/runs?head_sha=${target}&event=push&per_page=100`).workflow_runs;
  const check = runs.find((item) => item.head_sha === target && item.head_branch === "main");
  if (check?.status !== "completed" || check.conclusion !== "success") {
    throw new Error(`The latest main Check run for ${target} must succeed before releasing.`);
  }
  const ref = api(`git/ref/tags/${version}`, undefined, { missing: true });
  let object = ref?.object;
  for (let depth = 0; object?.type === "tag" && depth < 8; depth++) {
    object = api(`git/tags/${object.sha}`).object;
  }
  if (object && (object.type !== "commit" || object.sha !== target)) {
    throw new Error(`Tag ${version} does not point to the release commit.`);
  }
  if (draft && !ref && command("git", ["rev-parse", "--verify", `${draft.target_commitish}^{commit}`]) !== target) {
    throw new Error("The existing draft targets a different commit.");
  }
  if (mode === "prepare") return target;

  const names = [`Necto-${version}.dmg`, `Necto-${version}.dmg.sha256`, `necto-bridge-${version}.tgz`, `create-necto-plugin-${version}.tgz`];
  const files = names.map((name) => {
    const data = readFileSync(join(directory, name));
    if (!data.length) throw new Error(`Empty release artifact: ${name}`);
    return { name, size: data.length, digest: digest(data) };
  });
  const checksum = readFileSync(join(directory, names[1]), "utf8").trim();
  if (checksum !== `${files[0].digest.slice(7)}  ${names[0]}`) throw new Error("DMG checksum mismatch.");
  // An unpublished draft can contain a partial previous attempt. Uploaded files are
  // reused only when their content matches; conflicting files require explicit review.
  const existingAssets = draft ? api(`releases/${draft.id}/assets?per_page=100`) : [];
  for (const asset of existingAssets) {
    const file = files.find((item) => item.name === asset.name);
    if (!file || asset.state !== "uploaded" || asset.digest !== file.digest || asset.size !== file.size) {
      throw new Error(`Draft asset conflicts with this build: ${asset.name}`);
    }
  }
  if (!ref) api("git/refs", { ref: `refs/tags/${version}`, sha: target });
  if (!draft) {
    draft = api("releases", {
      tag_name: version, target_commitish: target, name: `Necto ${version}`,
      draft: true, prerelease: false, generate_release_notes: true,
    });
  }
  const missingFiles = files.filter((file) => !existingAssets.some((asset) => asset.name === file.name));
  if (missingFiles.length) {
    command("gh", ["release", "upload", version, ...missingFiles.map((file) => join(directory, file.name)), "--repo", repository]);
  }
  const latest = api(`releases/${draft.id}`);
  const currentRef = api(`git/ref/tags/${version}`);
  const expectedRef = ref?.object ?? { type: "commit", sha: target };
  if (currentRef.object.type !== expectedRef.type || currentRef.object.sha !== expectedRef.sha) {
    throw new Error("The release tag changed during upload.");
  }
  if (!latest.draft || latest.tag_name !== version) throw new Error("The release changed during upload.");
  const uploaded = api(`releases/${draft.id}/assets?per_page=100`);
  if (uploaded.length !== files.length || files.some((file) => !uploaded.some((asset) =>
    asset.name === file.name && asset.state === "uploaded" && asset.size === file.size && asset.digest === file.digest))) {
    throw new Error("Uploaded release assets did not pass verification.");
  }
  const download = `[**Download Necto**](https://github.com/${repository}/releases/download/${version}/Necto-${version}.dmg)`;
  const notes = latest.body ?? "";
  const body = notes.startsWith(download) ? notes : `${download}\n\n${notes}`;
  return api(`releases/${draft.id}`, { body, draft: false, prerelease: false, make_latest: "true" }, { method: "PATCH" }).html_url;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [mode, version, commit, ...extra] = process.argv.slice(2);
    if (extra.length || (mode === "prepare" && commit)) throw new Error("Unexpected arguments.");
    const result = release(mode, version, commit);
    if (mode === "prepare" && process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `commit=${result}\n`);
    console.log(result);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
