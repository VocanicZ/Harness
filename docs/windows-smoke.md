# Native Windows: set up a host and run the fleet smoke

Harness runs on native Windows (no WSL) under Git for Windows' bash with a native Python 3, on the
**headless session backend only**, and with **`claude` lanes only**: the other agent CLIs need tmux
panes, which Windows does not have. The decision and its trade-offs are in
[ADR 0001](adr/0001-native-windows-runtime.md); what the engine does differently there is in
[Native Windows](reference.md#native-windows).

This runbook sets up a Windows machine from scratch and runs `test/smoke/fleet_smoke.sh`, the one-issue
end-to-end check, on it (#357). The smoke files a trivial issue in a sandbox repo and lets a real fleet
claim it, run a headless `claude` lane, checkpoint and resume that lane mid-task, open a PR, merge it
and close the issue. It spends real `claude` quota and takes 10 to 30 minutes.

## 1. Install the prerequisites

On Windows 10 (19045 or later) or Windows 11, x64. In PowerShell:

```powershell
winget install --id Git.Git -e                # Git for Windows: bash, git, curl, sha256sum, tar
winget install --id Python.Python.3.13 -e     # a real Python 3 (the python3 on a stock PATH is a Store stub)
winget install --id GitHub.cli -e             # gh
irm https://claude.ai/install.ps1 | iex       # Claude Code (claude.exe in %USERPROFILE%\.local\bin)
```

Then:

- **Turn on Developer Mode** (Settings → For developers → Developer Mode). Harness makes real
  symlinks (`MSYS=winsymlinks:nativestrict`); without Developer Mode only an administrator can.
- **Open a new terminal** so the new PATH entries apply.
- **Optional, to run it over ssh:** Settings → Optional features → add *OpenSSH Server*, then
  `Start-Service sshd; Set-Service sshd -StartupType Automatic` in an administrator PowerShell.

tmux and Node are not needed.

## 2. Work in Git's bash, never WSL's

Open **Git Bash** from the Start menu. From cmd, PowerShell or ssh, start Git's bash by its full path:

```bat
"C:\Program Files\Git\bin\bash.exe" -l
```

A bare `bash` on the cmd `PATH` is `C:\Windows\System32\bash.exe`, which is **WSL's** bash. It runs a
Linux userland, not this host. Check where you are:

```sh
uname -s          # must start with MINGW64 (or MSYS) — anything else is the wrong bash
```

Every command below runs in Git Bash.

## 3. Sign in

```sh
gh auth login     # GitHub.com, HTTPS; the smoke creates a private sandbox repo with this login
claude            # sign in once (/login), then /exit
```

## 4. Get Harness and install it

```sh
git clone https://github.com/VocanicZ/Harness ~/Harness
cd ~/Harness
bash install.sh
```

The repo's `.gitattributes` checks the engine out with LF line endings, whatever Git's
`core.autocrlf` is set to; bash cannot run a CRLF script. `install.sh` writes a `python3` shim in
`~/.harness/bin` that runs the real interpreter, plus a `harness.cmd` that runs `harness` through Git's
`bash.exe` from cmd or PowerShell. It also checks the prerequisites above and names any that are missing.

Check the host:

```sh
uname -s                               # MINGW64_NT-…
~/.harness/bin/python3 --version       # Python 3.x, not the Store stub's message
gh auth status
claude --version
```

The smoke runs `harness doctor` too, after its sandbox is set up. The `windows:` section of that check
(headless backend, Git's bash, python3, symlinks, LF engine, `schtasks`/`powershell`/`taskkill`) is
written to the smoke's log, and every failure there names its fix.

## 5. Run the smoke

From Git Bash, in the Harness checkout:

```sh
bash test/smoke/fleet_smoke.sh claude
```

or from cmd, PowerShell or an ssh session, through the wrapper that runs Git's `bash.exe` by path:

```bat
%USERPROFILE%\Harness\test\smoke\fleet_smoke.cmd claude
```

```sh
ssh winsma '%USERPROFILE%\Harness\test\smoke\fleet_smoke.cmd claude'    # from another host (sshd's default shell, cmd)
```

On Windows the smoke defaults to `SMOKE_BACKEND=headless`. It refuses `SMOKE_BACKEND=tmux` and any CLI
but `claude`, and exits 2 before it touches GitHub. Keep the shell or ssh session open until it prints
its result: the fleet it starts is detached and outlives the session, but the smoke's own wait and
teardown run in the foreground. Every `SMOKE_*` setting in the script's header applies here as on
Linux. These are the ones that matter on a Windows host:

| Setting | Use |
|---|---|
| `SMOKE_EXTRA_CONFIG=<file>` | lines appended to the sandbox's `.harness/config`, e.g. `: "${HARNESS_CLAUDE_BIN:=/c/Users/me/.local/bin/claude.exe}"` when `claude` is not on Git Bash's PATH, or `: "${HARNESS_USAGE_CHECKPOINT_PCT:=99}"` on an account already near a usage limit |
| `SMOKE_REPO=<owner>/<repo>` | the sandbox (default `<gh login>/harness-smoke-claude`, created private on first use) |
| `SMOKE_TIMEOUT` | seconds to wait for the issue to close (3600) |
| `HARNESS_BASH_EXE` | Git's `bin\bash.exe`, for the `.cmd` wrapper, when Git is not in `C:\Program Files\Git` |

## 6. Read the result

The run ends with `== result: PASS` (exit 0) or `== result: FAIL (rc N)` (exit 1). The log is
`${TMPDIR:-/tmp}/harness-smoke/claude-headless-windows-<UTC stamp>.log` (`SMOKE_LOG` overrides); Git
Bash's `/tmp` is your `%TEMP%`. The log opens with these lines:

```
== fleet smoke | cli=claude | <claude --version> | <date>
== host windows | MINGW64_NT-10.0-… | bash 5.x | python3 3.x
== session backend headless | checkpoint+resume on, 30s into the lane
```

A pass shows every step: `harness init` / `setup` / `doctor` / `start`, the lane seen through the session
seam, `after checkpoint: labels=…agent-paused…`, `== resume: harness resume`, the resumed lane carrying
on its agent session, the merged PR and `smoke/<stamp>.txt` on the default branch. Teardown stops the
fleet with `harness stop --clean`, closes anything left open in the sandbox, deletes its branches and
removes the clone.

Commit a recorded run under `test/smoke/logs/`. That is the human-run follow-up, #358. That run also
checks the items ADR 0001 leaves open: renaming over the engine's directory symlink (`mv -T`), the
fleet's processes surviving the end of the ssh session that started them, and whether Claude Code runs
the `.sh` Stop hook on Windows. File each failure as its own issue.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `uname -s` prints `Linux` | you are in WSL's bash: open Git Bash, or start `"C:\Program Files\Git\bin\bash.exe"` by path |
| `Python was not found; run without arguments to install from the Microsoft Store` | the Store stub: install Python (step 1), re-run `bash install.sh` for the shim, or set `HARNESS_PYTHON` |
| `$'\r': command not found` | a CRLF engine: re-clone (the `.gitattributes` keeps it LF), or `git config --global core.autocrlf false` and re-clone |
| `ln -s` made a copy, or doctor says `symlinks: cannot create one` | turn on Developer Mode, or run as an administrator |
| `fleet_smoke: native Windows has no tmux` | unset `SMOKE_BACKEND`, or set it to `headless` |
| `fleet_smoke: '<cli>' is tmux-only` | only `claude` has a headless lane runner: run `fleet_smoke.sh claude` |
| `fleet_smoke.cmd: no Git bash.exe at …` | Git for Windows is elsewhere: set `HARNESS_BASH_EXE` to its `bin\bash.exe` |
| the issue never gets claimed | read `harness doctor`'s `windows:` lines in the log, then `harness --state-dir <clone>/.harness status` while it runs |
