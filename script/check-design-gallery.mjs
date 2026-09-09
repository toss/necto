//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const [contentView, splitView, layout, settings, components, galleryCSS, galleryJS, galleryHTML] =
  await Promise.all([
    "Necto/ContentView.swift",
    "Necto/NectoSplitView.swift",
    "Necto/UI/NectoLayout.swift",
    "Necto/SettingsScreen.swift",
    "WebPackages/Bridge/components.css",
    "docs/design/gallery.css",
    "docs/design/gallery.js",
    "docs/design/index.html",
  ].map((path) => readFile(resolve(root, path), "utf8")));

const problems = [];

function captured(source, expression, label) {
  const match = source.match(expression);
  if (!match) {
    problems.push(`could not read ${label}`);
    return undefined;
  }
  return match[1];
}

const sidebarWidth = captured(splitView, /setPosition\((\d+), ofDividerAt: 0\)/, "sidebar width");
const gallerySidebarWidth = captured(
  galleryCSS,
  /\.win > \.necto-sidebar\s*\{\s*width:\s*(\d+)px/,
  "gallery sidebar width",
);
if (sidebarWidth !== gallerySidebarWidth) {
  problems.push(`gallery sidebar is ${gallerySidebarWidth}px, Swift default is ${sidebarWidth}pt`);
}

const navWidth = captured(layout, /defaultWidth: CGFloat \{ (\d+) \}/, "settings nav width");
const navBlock = captured(components, /\.necto-nav\s*\{([\s\S]*?)\}/, "web settings nav");
const webNavWidth = navBlock && captured(navBlock, /width:\s*(\d+)px/, "web settings nav width");
if (navWidth !== webNavWidth || !navBlock?.includes("box-sizing: border-box")) {
  problems.push(`web settings nav must be a border-box matching Swift's ${navWidth}pt default`);
}

for (const label of ["Device Plugins", "Desktop Plugins"]) {
  if (!contentView.includes(`title: NectoL10n.text("${label}")`) || !galleryJS.includes(`>${label}<`)) {
    problems.push(`${label} is not represented in both the sidebar and gallery`);
  }
}
if (!settings.includes('(.plugins, NectoL10n.text("Desktop Plugins")') || !galleryJS.includes(">Desktop Plugins</span>")) {
  problems.push("Settings and the gallery disagree on the Desktop Plugins page name");
}

const grants = captured(galleryJS, /const grants = \[([\s\S]*?)\n\];/, "gallery approval grants");
if (grants?.includes("necto.device.")) {
  problems.push("the desktop plugin approval mock contains a device bridge");
}

const version = captured(galleryJS, /"nectoVersion":\s*"([^"]+)"/, "gallery Necto version");
if (version && !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version)) {
  problems.push(`the Plugin Sample mock does not report a semantic Necto version: ${version}`);
}

const generalPage = captured(
  galleryJS,
  /const generalPage = \(\) => `([\s\S]*?)`;\n\nconst pluginsPage/,
  "gallery general settings",
);
if (generalPage?.includes('aria-label="Appearance"')) {
  problems.push("the gallery shows an appearance preference that Settings does not have");
}

for (const stylesheet of ["../../WebPackages/Bridge/theme.css", "../../WebPackages/Bridge/components.css"]) {
  if (!galleryHTML.includes(`href="${stylesheet}"`)) {
    problems.push(`the gallery does not import ${stylesheet}`);
  }
}

if (problems.length) {
  console.error("FAIL: design gallery harness");
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log("OK: the gallery matches the current shell layout and plugin model.");
