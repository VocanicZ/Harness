#!/usr/bin/env node
// harness-install.js — the npx entry (#342): `npx -y github:VocanicZ/Harness` runs install.sh with
// bash, exactly as `curl … | bash` does. The package carries only install.sh and this file, so
// install.sh finds no checkout beside it and installs the published release, as a piped install does.
'use strict';
const path = require('path');
const { spawnSync } = require('child_process');

// On Windows, npx's `bash` is WSL's (C:\Windows\System32\bash.exe), which would install into WSL: point
// at the native install, from Git Bash (docs/windows-smoke.md, #357), and at WSL2 as the alternative.
if (process.platform === 'win32') {
  console.error('On native Windows, install Harness from Git Bash (headless claude lanes only, see\n' +
    'https://github.com/VocanicZ/Harness/blob/main/docs/windows-smoke.md):\n' +
    '  curl -fsSL https://raw.githubusercontent.com/VocanicZ/Harness/main/install.sh | bash\n' +
    'or run it inside WSL2:\n' +
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
