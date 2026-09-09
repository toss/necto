//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const arch = process.arch === 'arm64' ? 'arm64' : process.arch === 'x64' ? 'x86_64' : null;
if (!arch || process.platform !== 'darwin') throw new Error('The native cache checks require macOS');
function run(command, args, options = {}) {
  return execFileSync(command, args, { cwd: root, stdio: 'inherit', ...options });
}

run('swift', ['build', '--package-path', 'NectoMac', '--target', 'NectoMacService']);
const products = run('swift', ['build', '--package-path', 'NectoMac', '--show-bin-path'], { encoding: 'utf8', stdio: 'pipe' }).trim();
// Use SwiftPM's current object map: old checkouts can leave obsolete .o files behind.
const objects = ['NectoModel', 'NectoMacService', 'NectoTransport', 'NectoCLIService'].flatMap(module => {
  const mapping = JSON.parse(readFileSync(join(products, `${module}.build`, 'output-file-map.json'), 'utf8'));
  return Object.values(mapping).flatMap(entry => entry.object ? [entry.object] : []);
});
const sandbox = mkdtempSync(join(tmpdir(), 'necto-cache-check-'));
const executable = join(sandbox, 'device-plugin-store-check');
try {
  run('xcrun', [
    'swiftc', '-parse-as-library', '-swift-version', '6', '-target', `${arch}-apple-macos14.0`,
    '-I', join(products, 'Modules'),
    'Necto/NectoInstalledPlugin.swift', 'Necto/NectoDevicePluginStore.swift',
    'script/tests/device-plugin-store.swift', ...objects, '-o', executable,
  ]);
  run(executable, [], { env: { ...process.env, CFFIXED_USER_HOME: sandbox } });
} finally {
  rmSync(sandbox, { recursive: true, force: true });
}
