//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const theme = await readFile(resolve(root, "WebPackages/Bridge/theme.css"), "utf8");
const swift = await readFile(resolve(root, "Necto/NectoTheme.swift"), "utf8");
const host = await readFile(resolve(root, "Necto/NectoPluginWebView.swift"), "utf8");

const problems = [];

function cssColour(themeName, step) {
  const match = theme.match(new RegExp(`--${themeName}-${step}:\\s*#([0-9a-f]{6})`, "i"));
  if (!match) throw new Error(`missing --${themeName}-${step} in theme.css`);
  return match[1].toUpperCase();
}

const semanticSteps = {
  background: ["00", "00"],
  sidebar: ["05", "05"],
  surface: ["05", "10"],
  hover: ["10", "10"],
  selected: ["20", "20"],
  border: ["30", "30"],
  borderStrong: ["40", "40"],
  text: ["100", "100"],
  textSecondary: ["70", "70"],
  textTertiary: ["60", "60"],
  accent: ["100", "100"],
  brand: ["brand", "brand"],
  success: ["success", "success"],
  warning: ["warning", "warning"],
  danger: ["danger", "danger"],
  info: ["info", "info"],
};

for (const [name, [lightStep, darkStep]] of Object.entries(semanticSteps)) {
  const match = swift.match(
    new RegExp(`static let ${name} = adaptive\\(light: 0x([0-9A-F]+), dark: 0x([0-9A-F]+)\\)`),
  );
  if (!match) {
    problems.push(`NectoTheme.${name} is missing or no longer adaptive`);
    continue;
  }

  const expectedLight = cssColour("light", lightStep);
  const expectedDark = cssColour("dark", darkStep);
  if (match[1] !== expectedLight || match[2] !== expectedDark) {
    problems.push(
      `NectoTheme.${name} is ${match[1]}/${match[2]}, expected ${expectedLight}/${expectedDark}`,
    );
  }
}

for (const step of ["00", "05", "10", "20", "30"]) {
  const colour = cssColour("light", step).toLowerCase();
  const declaration = `setProperty('--light-${step}', '#${colour}')`;
  if (!host.includes(declaration)) {
    problems.push(`the WebView host does not reassert --light-${step} as #${colour}`);
  }
}

if (!host.includes('"var(--necto-base-10)" : "var(--necto-base-05)"')) {
  problems.push("the WebView host does not pin surface for both appearances");
}

const panelRoot = resolve(root, "Sources/NectoDefaultPlugins/Panels");
const builtCSS = (await readdir(panelRoot, { withFileTypes: true }))
  .filter((entry) => entry.isDirectory())
  .map((entry) => resolve(panelRoot, entry.name, "assets/index.css"));
builtCSS.push(resolve(root, "WebPackages/BuiltInPlugins/Plugins/plugin-sample/assets/index.css"));
builtCSS.push(resolve(root, "WebPackages/BuiltInPlugins/Plugins/shell-demo/assets/index.css"));

for (const path of builtCSS) {
  const css = await readFile(path, "utf8");
  for (const step of ["00", "05", "10", "20", "30"]) {
    const colour = cssColour("light", step).toLowerCase();
    if (!new RegExp(`--light-${step}:\\s*#${colour}`).test(css)) {
      problems.push(`${path.replace(`${root}/`, "")} has stale --light-${step}`);
    }
  }
  if (!/--necto-surface:\s*var\(--necto-base-05\)/.test(css)) {
    problems.push(`${path.replace(`${root}/`, "")} has a stale light surface`);
  }
}

if (problems.length) {
  console.error("FAIL: design token harness");
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log("OK: Swift, WebView host and built panels share the current design tokens.");
