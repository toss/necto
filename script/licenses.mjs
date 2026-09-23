//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const require = createRequire(import.meta.url);

export async function packageNotice(directory) {
  const manifest = JSON.parse(await readFile(join(directory, "package.json"), "utf8"));
  const files = (await readdir(directory)).filter((name) => /^(licen[sc]e|copying|notice)(\.|$)/i.test(name)).sort();
  if (!files.some((name) => /^(licen[sc]e|copying)(\.|$)/i.test(name))) {
    // This published package omits its upstream license file.
    if (manifest.name === "@docsearch/css" && manifest.version === "3.8.2") {
      return `${manifest.name} ${manifest.version}\n\n${await readFile(join(root, "script/licenses/DocSearch-3.8.2.txt"), "utf8")}`;
    }
    throw new Error(`Missing license for ${manifest.name} at ${directory}`);
  }
  const texts = await Promise.all(files.map(async (name) => `${name}\n\n${await readFile(join(directory, name), "utf8")}`));
  return `${manifest.name} ${manifest.version}\n\n${texts.join("\n\n")}`;
}

async function notices(sections) {
  return [`Necto\n\n${await readFile(join(root, "LICENSE"), "utf8")}`, ...sections].join("\n\n====================\n\n") + "\n";
}

export async function writeAppNotices(app) {
  const peerTalkLicense = await readFile(join(root, "LICENSES/PeerTalk.txt"), "utf8");
  const swiftLicense = await readFile(join(root, "NectoMac/.build/checkouts/swift-argument-parser/LICENSE.txt"), "utf8");
  const boringSSLRevision = "817ab07ebb53da35afea409ab9328f578492832d";
  const sslManifest = await readFile(join(root, "NectoMac/.build/checkouts/swift-nio-ssl/Package.swift"), "utf8");
  // swift-nio-ssl links to BoringSSL's license but omits its text from the checkout.
  if (!sslManifest.includes(`// BoringSSL Commit: ${boringSSLRevision}\n`)) {
    throw new Error("BoringSSL revision changed. Review and update its supplemental license before packaging.");
  }
  const boringSSLLicense = await readFile(join(root, "script/licenses/BoringSSL-817ab07.txt"), "utf8");
  const transportLicenses = await Promise.all([
    "swift-nio", "swift-nio-ssl", "swift-atomics", "swift-collections", "swift-system",
  ].map(async name => {
    const directory = join(root, "NectoMac/.build/checkouts", name);
    const license = await readFile(join(directory, "LICENSE.txt"), "utf8");
    const notice = ["swift-nio", "swift-nio-ssl"].includes(name)
      ? await readFile(join(directory, "NOTICE.txt"), "utf8") : "";
    return `${name}\n\n${license}\n${notice}`;
  }));
  const vite = await packageNotice(dirname(require.resolve("vite/package.json")));
  const resources = join(app, "Contents/Resources");
  await mkdir(resources, { recursive: true });
  await writeFile(join(resources, "THIRD_PARTY_NOTICES.txt"), await notices([
    `PeerTalk — https://github.com/rsms/peertalk\n\n${peerTalkLicense}`,
    `swift-argument-parser\n\n${swiftLicense}`, ...transportLicenses,
    `BoringSSL ${boringSSLRevision}\n\n${boringSSLLicense}`, vite,
  ]));
}

async function modulePackage(id) {
  if (id.startsWith("\0") || !id.includes("/node_modules/")) return;
  let directory = dirname(id.split("?")[0]);
  while (directory.includes("/node_modules/")) {
    try {
      const manifest = JSON.parse(await readFile(join(directory, "package.json"), "utf8"));
      if (manifest.name && manifest.version) return directory;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    directory = dirname(directory);
  }
  throw new Error(`Cannot identify bundled dependency: ${id}`);
}

export function docsLicensePlugin() {
  let ssr = false;
  return {
    name: "necto-license-notices",
    apply: "build",
    configResolved(config) { ssr = Boolean(config.build.ssr); },
    async generateBundle(_options, bundle) {
      if (ssr) return;
      const directories = new Set();
      for (const output of Object.values(bundle)) {
        if (output.type !== "chunk") continue;
        for (const id of Object.keys(output.modules)) {
          const directory = await modulePackage(id);
          if (directory) directories.add(directory);
        }
      }
      // The preload polyfill is a virtual module, not a node_modules file.
      const vitepressRequire = createRequire(require.resolve("vitepress/package.json"));
      directories.add(dirname(vitepressRequire.resolve("vite/package.json")));
      const sections = await Promise.all([...directories].sort().map(packageNotice));
      sections.push(`Inter font\n\n${await readFile(join(root, "script/licenses/Inter.txt"), "utf8")}`);
      this.emitFile({ type: "asset", fileName: "THIRD_PARTY_NOTICES.txt", source: await notices(sections) });
    },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error("Usage: node script/licenses.mjs <Necto.app>");
  await writeAppNotices(resolve(process.argv[2]));
}
