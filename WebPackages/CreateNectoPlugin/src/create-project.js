//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const publicRepositoryURL = "https://github.com/toss/necto";

export async function createProject({
  name,
  type,
  cwd = process.cwd(),
  bridgeSpec,
  nectoVersion,
  nectoRepositoryURL = `${publicRepositoryURL}.git`,
} = {}) {
  if (type !== "device" && type !== "desktop") {
    throw new Error("Plugin type must be device or desktop.");
  }

  const names = makeNames(name);
  const directory = resolve(cwd, name);
  await assertEmpty(directory);

  const version = nectoVersion ?? await packageVersion();
  const replacements = {
    "__BUNDLE_ID__": `com.example.${names.projectName.toLowerCase()}.example`,
    "__DISPLAY_NAME__": names.displayName,
    "__NECTO_BRIDGE_SPEC__": bridgeSpec ?? `${publicRepositoryURL}/releases/download/${version}/necto-bridge-${version}.tgz`,
    "__NECTO_REPOSITORY_URL__": nectoRepositoryURL,
    "__NECTO_VERSION__": version,
    "__PLUGIN_ID__": names.pluginID,
    "__PLUGIN_MODULE__": names.pluginModule,
    "__PROJECT_NAME__": names.projectName,
  };

  const template = resolve(packageRoot, "templates", type);
  await renderDirectory(template, directory, replacements);

  return {
    directory,
    relativeDirectory: relative(cwd, directory) || ".",
    type,
    ...names,
  };
}

function makeNames(name) {
  if (typeof name !== "string" || !/^[A-Za-z][A-Za-z0-9_-]*$/.test(name)) {
    throw new Error("Plugin name must start with a letter and contain only letters, numbers, - or _.");
  }

  const projectName = name
    .split(/[-_]+/)
    .filter(Boolean)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join("");
  const pluginModule = projectName.endsWith("Plugin") ? projectName : `${projectName}Plugin`;
  const words = projectName.replace(/([a-z0-9])([A-Z])/g, "$1 $2");
  const pluginID = `com.example.${words.toLowerCase().replaceAll(" ", "-")}`;

  return { displayName: words, pluginID, pluginModule, projectName };
}

async function packageVersion() {
  const manifest = JSON.parse(await readFile(resolve(packageRoot, "package.json"), "utf8"));
  return manifest.version;
}

async function assertEmpty(directory) {
  try {
    const entries = await readdir(directory);
    if (entries.length > 0) throw new Error(`Directory is not empty: ${directory}`);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

async function renderDirectory(source, destination, replacements) {
  await mkdir(destination, { recursive: true });
  for (const entry of await readdir(source, { withFileTypes: true })) {
    const outputName = replace(entry.name, replacements);
    const sourcePath = resolve(source, entry.name);
    const destinationPath = resolve(destination, outputName);

    if (entry.isDirectory()) {
      await renderDirectory(sourcePath, destinationPath, replacements);
      continue;
    }

    const metadata = await stat(sourcePath);
    const contents = replace(await readFile(sourcePath, "utf8"), replacements);
    await mkdir(dirname(destinationPath), { recursive: true });
    await writeFile(destinationPath, contents, { mode: metadata.mode });
  }
}

function replace(value, replacements) {
  return Object.entries(replacements).reduce(
    (result, [token, replacement]) => result.replaceAll(token, replacement),
    value,
  );
}
