//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { access, readFile, readdir, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const panelRoots = [];
for (const entry of await readdir(resolve(root, "SDK/iOS/Sources"), { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const panelRoot = resolve(root, "SDK/iOS/Sources", entry.name, "Panels");
  let panels;
  try { panels = await readdir(panelRoot, { withFileTypes: true }); }
  catch (error) { if (error.code === "ENOENT") continue; throw error; }
  panelRoots.push(...panels.filter(entry => entry.isDirectory()).map(entry => resolve(panelRoot, entry.name)));
}
panelRoots.push(resolve(root, "WebPackages/BuiltInPlugins/Plugins/plugin-sample"));
panelRoots.push(resolve(root, "WebPackages/BuiltInPlugins/Plugins/shell-demo"));

const problems = [];
const assetPattern = /<(?:script|link)\b[^>]*(?:src|href)=["']([^"']+)["'][^>]*>/gi;

for (const panelRoot of panelRoots) {
  const htmlPath = resolve(panelRoot, "index.html");
  let html;
  try {
    html = await readFile(htmlPath, "utf8");
  } catch {
    problems.push(`${panelRoot.replace(`${root}/`, "")} has no index.html`);
    continue;
  }

  for (const match of html.matchAll(assetPattern)) {
    const reference = match[1];
    if (/^(?:[a-z]+:|\/\/|#)/i.test(reference)) continue;
    const assetPath = resolve(dirname(htmlPath), reference.split(/[?#]/, 1)[0]);
    if (!assetPath.startsWith(`${panelRoot}/`)) {
      problems.push(`${htmlPath.replace(`${root}/`, "")} references an asset outside its panel: ${reference}`);
      continue;
    }
    try {
      if ((await stat(assetPath)).size === 0) {
        problems.push(`${assetPath.replace(`${root}/`, "")} is empty`);
      } else {
        await access(assetPath);
      }
    } catch {
      problems.push(`${htmlPath.replace(`${root}/`, "")} references missing ${reference}`);
    }
  }
}

if (problems.length) {
  console.error("FAIL: panel asset harness");
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log("OK: every built panel has an entry point and its referenced assets.");
