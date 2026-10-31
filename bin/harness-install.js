#!/usr/bin/env node
// harness-install.js — the npx entry (#342): `npx -y github:VocanicZ/Harness` runs install.sh with
// bash, exactly as `curl … | bash` does. The package carries only install.sh and this file, so
// install.sh finds no checkout beside it and installs the published release, as a piped install does.
'use strict';
const path = require('path');
const { spawnSync } = require('child_process');

if (process.platform === 'win32') {
  console.error('Harness runs on Linux and macOS. On Windows, run it inside WSL2:\n' +
    '  wsl npx -y github:VocanicZ/Harness');
  process.exit(1);
}
const installer = path.join(__dirname, '..', 'install.sh');
const r = spawnSync('bash', [installer, ...process.argv.slice(2)], { stdio: 'inherit' });
if (r.error) {
  console.error(`harness install: could not run bash ${installer}: ${r.error.message}`);
  process.exit(1);
}
process.exit(r.status === null ? 1 : r.status);
