#!/usr/bin/env node
// harness-install.js — the npx entry (#342): `npx -y github:VocanicZ/Harness` runs install.sh with
// bash, exactly as `curl … | bash` does. The package carries only install.sh and this file, so
// install.sh finds no checkout beside it and installs the published release, as a piped install does.
'use strict';
const path = require('path');
const { spawnSync } = require('child_process');

// gitBash — Git for Windows' bash.exe, or null. On Windows npx's plain `bash` may be WSL's
// (C:\Windows\System32\bash.exe), which would install into WSL, so the installer runs under Git's by path:
// HARNESS_BASH_EXE, else the Git for Windows root (EXEPATH inside Git Bash, `git --exec-path`, the usual
// install dirs), and only a bash that answers MINGW/MSYS to `uname -s` counts.
function gitBash() {
  const fs = require('fs');
  const cands = [process.env.HARNESS_BASH_EXE];
  if (process.env.EXEPATH) cands.push(path.join(process.env.EXEPATH, 'bin', 'bash.exe'));
  const g = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
  if (!g.error && g.status === 0) cands.push(path.join(g.stdout.trim(), '..', '..', '..', 'bin', 'bash.exe'));
  for (const d of [process.env.ProgramFiles, process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Programs')]) {
    if (d) cands.push(path.join(d, 'Git', 'bin', 'bash.exe'));
  }
  for (const c of cands) {
    if (!c || !fs.existsSync(c)) continue;
    const u = spawnSync(c, ['-c', 'uname -s'], { encoding: 'utf8' });
    if (!u.error && /^(MINGW|MSYS)/.test(u.stdout)) return c;
  }
  return null;
}
let bash = 'bash';
if (process.platform === 'win32') {
  bash = gitBash();
  if (!bash) {
    console.error('On native Windows, Harness installs under Git for Windows\' bash (https://gitforwindows.org), and\n' +
      'no Git bash was found. Install Git for Windows (winget install --id Git.Git -e), then run this again\n' +
      'from Git Bash, or run it inside WSL2:\n' +
      '  wsl npx -y github:VocanicZ/Harness');
    process.exit(1);
  }
}
const installer = path.join(__dirname, '..', 'install.sh');
// Git's bash takes a Windows path with forward slashes.
const script = process.platform === 'win32' ? installer.replace(/\\/g, '/') : installer;
const r = spawnSync(bash, [script, ...process.argv.slice(2)], { stdio: 'inherit' });
if (r.error) {
  console.error(`harness install: could not run ${bash} ${installer}: ${r.error.message}`);
  process.exit(1);
}
process.exit(r.status === null ? 1 : r.status);
