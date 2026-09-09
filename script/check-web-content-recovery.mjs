//
// Copyright (c) 2026 Viva Republica, Inc.
//
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
if (process.platform !== 'darwin') throw new Error('WebView recovery checks require macOS');
const scratch = process.env.NECTO_TEST_SCRATCH ? ['--scratch-path', process.env.NECTO_TEST_SCRATCH] : [];
const run = (command, args, options = {}) => execFileSync(command, args, { cwd: root, stdio: 'inherit', ...options });
run('swift', ['build', '--package-path', 'NectoMac', ...scratch, '--target', 'NectoMacService']);
const products = run('swift', ['build', '--package-path', 'NectoMac', ...scratch, '--show-bin-path'], { stdio: 'pipe', encoding: 'utf8' }).trim();
const objects = ['NectoModel', 'NectoMacService', 'NectoTransport', 'NectoCLIService'].flatMap(module => {
  const mapping = JSON.parse(readFileSync(join(products, `${module}.build`, 'output-file-map.json'), 'utf8'));
  return Object.values(mapping).flatMap(entry => entry.object ? [entry.object] : []);
});
const temporary = mkdtempSync(join(tmpdir(), 'necto-web-recovery-'));
try {
  const executable = join(temporary, 'recovery-check');
  run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6', '-target', `${arch}-apple-macos14.0`,
    '-I', join(products, 'Modules'),
    'Necto/NectoPluginWebView.swift', 'Necto/NectoPluginSchemeHandler.swift',
    'Necto/NectoInstalledPlugin.swift', 'Necto/NectoFindBar.swift', 'Necto/NectoTheme.swift',
    'Necto/NectoLocalization.swift', 'Necto/UI/NectoControls.swift',
    'script/tests/web-content-recovery.swift', 'script/tests/web-content-security.swift', ...objects, '-o', executable]);
  run(executable, [], { timeout: 90_000 });
} finally { rmSync(temporary, { recursive: true, force: true }); }
