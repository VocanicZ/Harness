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

On Windows 10 (19045 or later) or Windows 11, x64. **The short way:** install Git for Windows
(`winget install --id Git.Git -e`), open Git Bash and run `bash install.sh` (step 4). On a Windows
host `install.sh` offers every other prerequisite through **winget**, as it does with apt or brew on
Linux, and asks before each one:

| Missing | winget id |
|---|---|
| Git for Windows (git, curl, sha256sum, tar) | `Git.Git` |
| a Python 3 that runs (the Store stub does not count) | `Python.Python.3.13` |
| `gh` | `GitHub.cli` |
| an agent CLI | `Anthropic.ClaudeCode` |
| Node, for rtdd's installer | `OpenJS.NodeJS.LTS` |

`HARNESS_INSTALL_PREREQS=1` accepts every offer without asking, `0` declines them all (the commands
are printed instead); `HARNESS_WINGET` names the winget binary (the test suite points it at a stub). winget
updates PATH for new terminals only, so open a new Git Bash if a prerequisite still reads `MISSING`.
It then checks Developer Mode and the git identity (step 3) and prints the exact fix for each.
Harness sets `core.longpaths=true`, `core.autocrlf=false` and `core.eol=lf` in its own repo and
worktrees (`git -C <worktree> config`, never `--global` or `--system`). WSL2 remains an optional
alternative: run the Linux instructions inside it.

To install by hand instead, in PowerShell:

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
git config --global user.name  "<your name>"     # the lane commits as this identity
git config --global user.email "<your GitHub noreply email>"
```

A fresh Git for Windows install has no git identity. `install.sh` and `harness doctor` check for one
and print these two commands when it is missing. Without it the lane's first commit fails and the agent has to pick an author itself (#358's
run saw it borrow one from the repo's history). To give a single run an identity without writing git
config, export `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` before
starting the smoke: the fleet inherits them.

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
(headless backend, Git's bash, python3, symlinks, LF engine, `schtasks`/`powershell`/`taskkill`, `gh`, an
agent CLI, rtdd, Developer Mode, the git identity and the checkout's per-repo git settings; `harness doctor --fix` writes
those settings) is
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

## Checking on a shared Windows host (`test/smoke/winsma/`)

The sections above set up a Windows machine you own. The helpers in `test/smoke/winsma/` (#479, PRD #475) are for the
opposite case: a lane on the claude host checks Harness on **a Windows desktop that does other work** (the owner's
`winsma`), over ssh, without leaving a trace. Set `HARNESS_WINDOWS_HOST` to the ssh alias (in `.harness/config` or the
environment; see [`docs/reference.md`](reference.md)); unset means there is no Windows host and every helper refuses to run.

The rules the helpers enforce, all from PRD #475's "Verification on winsma":

- **One run at a time: the lock.** `C:\hx-lock` is taken with an atomic `mkdir`; `owner` holds the issue, the lane's
  session name and its claude-host pid. A background heartbeat loop (started detached through PowerShell, its pid in
  `pids`, so it survives the ssh session and keeps going while one of your own commands blocks for hours) refreshes
  `heartbeat` every 5 minutes, and ends when the lock is gone. A held lock with a live heartbeat means **wait**: the
  helper polls every 5 minutes and never labels the issue `agent-paused`. A lock is stale only when its heartbeat is
  older than 30 minutes **and** the owner lane is no longer live on the claude host; the breaker then kills the
  stale run's `pids`, anything whose command line is under `C:\hx-<n>\`, deletes its `tasks` and its
  `~/.claude.json` project entries and `C:\hx-<n>\`, and takes the lock.
- **Isolation.** Everything runs in `C:\hx-<issue>\`. `harness`'s own state (`HARNESS_HOME`, `HARNESS_BIN_DIR`,
  `HARNESS_USER_SKILLS`), `TMPDIR`, `npm_config_cache`, `GIT_CONFIG_GLOBAL` (a fleet's `ensure_safe` writes `safe.directory` entries to the global git config, which must not be `~/.gitconfig`) and the clone live under it. Install, update and uninstall
  runs also set `CLAUDE_CONFIG_DIR`; the full suite also sets `HOME` and `USERPROFILE` to `C:\hx-<issue>\home`.
  Python packages go into a venv under the folder, never into the shared `python`. Tasks the run creates are
  registered logon-only (never a boot trigger) and recorded in `tasks`; processes it starts are recorded in `pids`.
- **The guard.** Before and after, it checksums `C:\Users\pc\.local\bin`, `~/.claude/settings.json`,
  `~/.claude/skills/`, the two plugin registries, `~/.gitconfig`, gh's config and `C:\Users\pc\.harness`; lists the
  `Harness\*` Task Scheduler tasks; and compares `~/.claude.json` only on its `projects` entries **outside**
  `C:\hx-<issue>` (plus top-level keys named in `WS_CLAUDE_TOP_KEYS`; Harness itself writes none). Any change fails
  the run.
- **Credentials.** `GH_TOKEN` goes in on the ssh session's **stdin**, git auth goes through `GIT_CONFIG_COUNT` env
  vars and the identity through `GIT_AUTHOR_*` / `GIT_COMMITTER_*`; nothing is written. At the end `scan` lists any
  file under the run folder, `%TEMP%`, `~/.claude/projects`, `~/.harness`, gh's config, `.gitconfig` or the bash
  history that holds the token and did not hold it before (paths only, never the token).
- **Cleanup.** Kill the recorded pids, delete the recorded tasks and the run's `~/.claude.json` entries, delete
  `C:\hx-<issue>\`, release the lock, then check winsma is clean. It only ever names the numbered folder, so
  `C:\hx-smoke\` is out of reach.

```sh
test/smoke/winsma/winsma.sh run 479 base 'echo hello'   # lock → isolate → guard → command → guard → scan → cleanup
test/smoke/winsma/winsma.sh lock 479 hz-main-i479 $PID   # or step by step: lock, isolate [--venv], guard before,
test/smoke/winsma/winsma.sh exec 479 install 'bash install.sh'   #   exec <issue> <base|install|suite> <cmd>,
test/smoke/winsma/winsma.sh guard 479 after              #   guard after, scan before|after, cleanup
test/smoke/winsma/winsma.sh cleanup 479
```

`run` exits non-zero if the command, the guard, the scan or the cleanup failed, and always cleans up. Log what you do
under `test/smoke/logs/` with a `-windows-` name (`WS_LOG=<file>` tees the helpers' own lines there).
Uninstall on a Windows host removes everything Harness put there (tasks, launchers, `harness.cmd`, the python3 shim, the
poller and fleet registry, skill links), and only that; a run is `winsma.sh run <issue> install '<script>'` with the script
installing, then `harness uninstall --force --force-engine`, then asserting `HARNESS_HOME`, `HARNESS_BIN_DIR` and
`HARNESS_USER_SKILLS` are empty (`test/smoke/logs/uninstall-windows-*.log`, #490).

Install, update and rollback on a Windows host (#491): `test/smoke/winsma/lifecycle.sh` is the script a run sends
(`winsma.sh run <issue> install "$(cat test/smoke/winsma/lifecycle.sh)"`). In stages, all inside `C:\hx-<issue>\` with a
logging winget stub and a `schtasks` wrapper that swallows `/Run` and `/End` (so a task is registered, logon-only and
per-home, but never started): `entry` (both install lines from Git Bash, the real network, `HARNESS_REF` pinned to a real
release, then again, then a different pin), `real` (the real previous release to this branch's tree, served over `file://`
with a `SHA256SUMS`: update, update again, rollback, forward, pin, uninstall), `tasks` (the same with the supervise and web
tasks registered), `v011` (a v0.1.1 git checkout rebuilt inside the folder, updated, migrated, rolled back and forward),
`gitco` and `gitdef` (a git-checkout engine migrated, with an explicit and with the default home), and `prune` (five releases
leave three; a corrupted archive is refused). `harness doctor` runs after each state. The log is
`test/smoke/logs/lifecycle-windows-20261104T124219Z.log`.

Lane tooling and skills on a Windows host (#495): `test/smoke/winsma/tooling.sh` is the script a run sends
(`winsma.sh run <issue> install "$(cat test/smoke/winsma/tooling.sh)"`), in three stages inside `C:\hx-<issue>\`: `install` (this branch as
a local release; rtdd resolves to the host's own `rtdd.exe`, which is found and run but never installed — its installer writes skills
machine-wide), `skills` (`harness update --with-skills` into the sandbox `CLAUDE_CONFIG_DIR` and `HARNESS_USER_SKILLS`: the plugins are
registered there, `to-prd`, `to-issues`, `subagent-task-tree` and every skill a lane prompt names (`{{skill:…}}`) are in the skills dir)
and `lane` (a shell with a lane's env, a short `TMPDIR` and a worktree path with a space, running git, gh, `rtdd.exe`, python3 through the
shim, grep and sed). Log: `test/smoke/logs/tooling-windows-20261104T141533Z.log`.

`test/test_winsma.sh` covers all of it on Linux with a fake ssh, a fake `C:` drive, a fake Task Scheduler and a fake
process list: the host itself is only touched by a recorded run
(`test/smoke/logs/winsma-helpers-windows-20261104T013238Z.log`: the whole sequence with a trivial command, winsma clean after;
`test/smoke/logs/windows-installer-windows-20261104T041438Z.log`, #488: `install.sh` with a `HARNESS_WINGET` stub, `harness init`, `harness start` dispatching an issue, doctor green, guard clean;
`test/smoke/logs/task-names-windows-20261104T085249Z.log`, #489: two `HARNESS_HOME`s installed side by side get distinct, logon-only supervise and web tasks, removing one leaves the other, guard clean). **Developer Mode is off on winsma**: symlinks work
there only because the ssh session is an elevated administrator, so the non-admin path is covered by the
`HARNESS_PLATFORM=windows` fakes, not by a live run.

Knobs: `WS_POLL` (wait between lock polls, default 300 s), `WS_STALE_SEC` (default 1800), `WS_LOCK_TIMEOUT` (default
0 = wait as long as it takes), `WS_HB_INTERVAL` (default 300 s), `WS_LANE_SESSION` / `WS_LANE_PID` (what `lock` records
as the owner; pid defaults to the caller's parent).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `uname -s` prints `Linux` | you are in WSL's bash: open Git Bash, or start `"C:\Program Files\Git\bin\bash.exe"` by path |
| `Python was not found; run without arguments to install from the Microsoft Store` | the Store stub: install Python (step 1), re-run `bash install.sh` for the shim, or set `HARNESS_PYTHON` |
| `$'\r': command not found` | a CRLF engine: re-clone (the `.gitattributes` keeps it LF), or `git config --global core.autocrlf false` and re-clone |
| `ln -s` made a copy, or doctor says `symlinks: cannot create one` | turn on Developer Mode, or run as an administrator |
| `fleet_smoke: native Windows has no tmux` | unset `SMOKE_BACKEND`, or set it to `headless` |
| `fleet_smoke: '<cli>' is tmux-only` | only a CLI with a headless lane runner (`agy`, `claude`, `codex`, `hermes`, `openclaw`, `opencode`) runs on Windows: run `fleet_smoke.sh claude` |
| `fleet_smoke.cmd: no Git bash.exe at …` | Git for Windows is elsewhere: set `HARNESS_BASH_EXE` to its `bin\bash.exe` |
| the issue never gets claimed | read `harness doctor`'s `windows:` lines in the log, then `harness --state-dir <clone>/.harness status` while it runs |
| `install.sh`: `could not resolve the latest release … the response is not JSON` | an `install.sh` from before #403's fix ran the releases lookup with the Store-stub `python3` before the shim existed; a current one resolves it through the Python that runs and writes the shim first. On an older one: `HARNESS_REF=<tag> bash install.sh` (e.g. the latest from `gh release list -R VocanicZ/Harness`) |
| `harness start` exits with `install Python 3, then re-run install.sh/harness update for the shim, or set HARNESS_PYTHON` | no working `python3` (the Store stub, no shim): start refuses, since the fleet could never claim an issue (#405). Fix the install (above), then check `~/.harness/bin/python3 --version`. An engine from before #405 starts anyway and its worker log fills with `Python was not found…` |
| `checkpoint not confirmed: issue #N is not agent-paused`, the lane's screen is empty | Windows Python's cp1252 stdio breaks the headless lane's screen, so the stuck-turn interrupt never fires (#406): `export PYTHONUTF8=1` before the smoke |
