//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const sourceRoot = resolve(root, "WebPackages/BuiltInPlugins/src");
const plugins = (await readdir(sourceRoot, { withFileTypes: true }))
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();
const problems = [];

for (const plugin of plugins) {
  const source = await readFile(resolve(sourceRoot, plugin, "src/main.ts"), "utf8");
  const localization = await readFile(resolve(sourceRoot, plugin, "src/localization.ts"), "utf8");
  if (!source.includes('from "./localization"')) {
    problems.push(`${plugin} does not use its localization module`);
  }
  if (!localization.includes("createTranslator") || !localization.includes("ko:")) {
    problems.push(`${plugin} has no Korean translator dictionary`);
  }

  const panelRoot = ["plugin-sample", "shell-demo"].includes(plugin)
    ? resolve(root, "WebPackages/BuiltInPlugins/Plugins", plugin)
    : resolve(root, "Sources/NectoDefaultPlugins/Panels", plugin);
  const assets = resolve(panelRoot, "assets");
  const scripts = (await readdir(assets)).filter((name) => name.endsWith(".js"));
  const built = (await Promise.all(scripts.map((name) => readFile(resolve(assets, name), "utf8")))).join("\n");
  if (!/\p{Script=Hangul}/u.test(built)) {
    problems.push(`${plugin} built panel does not contain its Korean copy`);
  }
}

if (problems.length) {
  console.error("FAIL: plugin localization harness");
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log("OK: every built-in plugin owns Korean copy and ships it in its panel.");
