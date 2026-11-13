# Harness on native Windows: setup, daily use, the smoke and the Windows check host

Native Windows is a **first-class host**, not a reduced mode (PRD #475). The same features, skills, rtdd flow and
install, update, rollback and uninstall lifecycle that Linux has work in Git for Windows' bash with a native Python 3,
and every supported agent CLI runs its lanes there. WSL2 is optional: if you would rather run the Linux instructions
inside it, they work unchanged. The one structural difference is the session backend: Windows has no tmux, so lanes run
on the **headless session backend**, which draws the same screen from a lane's `state.json`, and `harness attach` drives
a headless lane directly (typed lines become the lane's next turn, Ctrl-C detaches and leaves it running), on every OS.
[Parity matrix](reference.md#windows-parity-matrix): one row per feature, each `✓` on both hosts but the Linux-only
HTCondor swarm service. How it works, and why: [ADR 0001](adr/0001-native-windows-runtime.md) and
[Native Windows](reference.md#native-windows).

| Agent CLI | Windows lane runner | Windows build of the CLI |
|---|---|---|
| `claude` | `scripts/cli/claude_headless.py` | Claude Code for Windows (`irm https://claude.ai/install.ps1 \| iex`, `winget install Anthropic.ClaudeCode`) |
| `codex` | `scripts/cli/codex_headless.py` (`codex exec --json`) | native on Windows, no WSL needed (Windows 11 recommended, Windows 10 1809+ best effort) |
| `opencode` | `scripts/cli/opencode_headless.py` (`opencode run`) | runs directly on Windows (`OPENCODE_GIT_BASH_PATH` names Git Bash; the vendor recommends WSL) |
| `copilot` | `scripts/cli/copilot_headless.py` | `winget install GitHub.Copilot` |
| `hermes` | `scripts/cli/hermes_headless.py` | native: `iex (irm https://hermes-agent.nousresearch.com/install.ps1)` |
| `openclaw` | `scripts/cli/openclaw_headless.py` (`openclaw agent exec --json`) | native Windows CLI and Gateway supported |
| `agy` | `scripts/cli/agy_headless.py` | PowerShell installer `irm https://antigravity.google/cli/install.ps1 \| iex` |

The vendors' pages and each CLI's non-interactive mode are in [reference.md](reference.md#non-interactive-mode-per-agent-cli).
All seven share one runner core (`scripts/cli/headless_core.py`) and differ only in a small per-CLI turn adapter.

This guide sets up a Windows machine from scratch (1 to 4), shows daily use (the next section), runs
`test/smoke/fleet_smoke.sh`, the one-issue end-to-end check, on it (#357; 5 and 6), and describes how Harness itself is
checked on a Windows desktop that does other work (`test/smoke/winsma/`, the last section). The smoke files a trivial issue
in a sandbox repo and lets a real fleet claim it, run a headless `claude` lane, checkpoint and resume that lane mid-task,
open a PR, merge it and close the issue. It spends real `claude` quota and takes 10 to 30 minutes.

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

## Daily use on Windows

Everything is the `harness` command, in Git Bash (or `harness.cmd` from cmd and PowerShell, which runs it through Git's
`bash.exe` by path). Per feature, Windows differs from Linux only where this table says:

| You do | On Windows |
|---|---|
| `harness init`, `start`, `status`, `stop`, `doctor` | as on Linux. `start` launches the workers detached, so they outlive the shell or ssh session; `stop` ends them by pid file |
| `harness attach <lane>` | live watch of the lane's screen; a typed line is queued as the lane's next turn; **Ctrl-C detaches** and leaves the lane running |
| `harness pause --force`, `resume` | checkpoint every lane to GitHub (`agent-paused` plus a handoff comment), then put the issues back in the pool |
| `harness supervise --install`, `web --install` | a Task Scheduler task in place of the systemd user unit: `Harness\harness-supervise`, `Harness\harness-web`. It starts at logon only (never at boot), needs no administrator, and the name carries a short hash of `HARNESS_HOME` when that is not `~/.harness`, so a second home never collides. A killed worker is brought back by the supervisor's next pass (`INTERVAL` in `supervise.conf`) |
| `harness web` | the read-only dashboard, `http://127.0.0.1:4637/` (`HARNESS_WEB_PORT`, `HARNESS_WEB_BIND`) |
| `harness stats`, `forecast`, `one`, `issue`, `prd`, `plan` | as on Linux; the event log is `$HARNESS_HOME/events.jsonl`; the injector (`issue`, `prd`, `plan`) is a headless lane named `hz-inject-<unit>` |
| `harness update`, `update --rollback`, `update --with-skills` | download, SHA256SUMS check, flip of the `engine` link (a real symlink), prune to the current release plus 2, redeploy of the shim, tasks and skill links; a second `--rollback` goes forward again |
| `harness uninstall [--force] [--force-engine]` | removes the fleet, `.harness/`, the engine and everything Harness put outside them: the Task Scheduler tasks and launchers, `harness`, `harness.cmd`, the python3 shim, the skill links, the registry and the poller. It never touches anything Harness did not create |
| rtdd | `rtdd.exe`, found on PATH or in its install dir |
| HTCondor swarm submission | not available (a Linux-only service): a Windows lane tests with rtdd locally, and `HARNESS_SWARM=off` in a Windows sandbox |

Windows rules worth knowing. **Symlinks:** Harness makes real ones (`MSYS=winsymlinks:nativestrict`), which need Developer
Mode or an administrator shell; `harness doctor` says which. **A directory cannot be renamed while a file inside it is open**,
so stop the fleet and leave an engine folder before `harness update`. **Upgrading from v0.1.1** (the oldest Windows install, a git checkout): run `harness update` twice. The first runs v0.1.1's own `update.sh`, which can only fast-forward the checkout, and ends with `Run 'harness update' once more`; the second, run by the code the first pulled, moves the engine onto a release (`engine -> releases/vX`, your checkout kept as `releases/git-<sha>`). No install line is needed. **Python:** the engine runs its own `python3` shim
(`$HARNESS_HOME/bin/python3`) in UTF-8 mode; the Microsoft Store stub is never used. **Paths:** `C:/x`, `/c/x` and `C:\x` all
reach the same file, but a path handed to a native program's command line must be in the `C:/x` form. **Line endings:** the
repo's `.gitattributes` keeps the engine LF; Harness sets `core.autocrlf=false` and `core.eol=lf` per repo, never globally.

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
without a headless runner, and exits 2 before it touches GitHub (`claude` is the one this guide runs; the others are checked on
the claude host, below). Keep the shell or ssh session open until it prints
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
  session name and its claude-host pid, `taken` the time it was taken. A background heartbeat loop (started detached
  through PowerShell, its pid in `pids`, so it survives the ssh session and keeps going while one of your own commands
  blocks for hours) refreshes `heartbeat` every 5 minutes, and ends when the lock is gone. A held lock with a live
  heartbeat means **wait**: the helper polls every 5 minutes and never labels the issue `agent-paused`. A lock is stale
  only when its heartbeat is older than 30 minutes **and** the owner lane is no longer live on the claude host; the
  breaker then kills the stale run's `pids`, anything whose command line is under `C:\hx-<n>\`, deletes its `tasks` and
  its `~/.claude.json` project entries and `C:\hx-<n>\`, and takes the lock.
- **A lane on an old branch fails fast** (#1041). Every lane runs the helpers from its own worktree, so a branch older than
  #1033 runs the take-when-free lock beside the queue and never sees the lock free. The host records the protocol in
  `C:\hx-proto` (1 = take-when-free, 2 = the queue); `lock` and `run` check the client's protocol (`WS_PROTO`, default 2)
  first and exit 1 at once, naming both protocols and telling the lane to rebase onto `origin/main`. A lane whose code
  predates the check cannot be stopped from the host: rebase it. The engine does it before the lane queues (#1050): with `HARNESS_WINDOWS_HOST` set, a chore (`winsma_stale_tick`, every
  `HARNESS_WINSMA_STALE_S`, default 120 s) sends a live lane whose `lock.sh` has no `ws_proto_check` one order to stop and rebase, and a lane
  launched or resumed on a pushed branch like that finds the order at the top of its task file.
- **Fair and bounded: the queue and the hold cap** (#1033). One lane used to hold the lock for 12 hours while six others
  waited, and whichever waiter's poll landed first won each release. Now the lock is **FIFO**: a lane that finds it held
  takes a ticket in `C:\hx-queue\<stamp>-<issue>` (issue, session, host pid; refreshed on every poll; one ticket per
  issue) and `lock` succeeds only for the oldest ticket, or when the queue is empty. A ticket whose refresh is older
  than `WS_STALE_SEC` **and** whose lane is gone is dropped by the next waiter, so a dead lane cannot block the line.
  A lane that releases and asks again goes to the **back**, behind every ticket that already exists.
  The hold is **capped**: `winsma.sh run` is one acquisition for exactly one command and releases at the end. On the
  step-by-step path (`lock`, then `exec` …), once the lock has been held longer than `WS_HOLD_MAX` (default 5400 s,
  90 minutes) **and** another lane is queued, `exec` refuses to start a new command (`hold cap reached, N lane(s)
  queued: release and re-queue`, exit 3): clean up, `cleanup <issue>`, and `lock` again (you queue at the back). An
  `exec` that is already running is never killed for this. With nobody queued the cap does not apply. Do not plan to
  work in one lock session for hours: run one test file or one matrix per acquisition and re-queue between them.
  The cap does not rely on `exec`: the lock's **heartbeat loop** enforces it (#1040). Once the hold passes `WS_HOLD_MAX` and a
  live ticket of another lane is queued, the loop **releases the lock and ends**, whatever the holder is doing, so a
  background "driver" script (`lock`, `isolate`, a `while … sleep` loop, `cleanup`) that never calls `exec` loses the lock
  too. Do not write one: it holds a lock nothing is using, since the lane's turn ends while it runs. A lock taken by `run`
  is cut short only by the hard ceiling below. The lock is also tied to the lane being **working**: a waiter that finds the
  holder's session idle (turn ended, or exited) notes it, and once it has sat idle longer than `WS_IDLE_MAX` (default 600 s)
  the first lane in the queue cleans the holder's run and releases the lock. A lock taken by `winsma.sh run` is exempt (#1062): its lane's pid and tmux session are not visible from the waiter's own sandbox, so "not working" there proves nothing, and a run in flight ends only at the hard ceiling below. `WS_POLL` below the rule (300 s) is clamped
  to it, so a lane cannot win every free-lock race by polling faster; only `WS_POLL_MIN` (a test seam) lowers the floor.
  As protection against a single runaway command there is a **hard ceiling**, `WS_HOLD_HARD` (default 3 × `WS_HOLD_MAX`,
  4.5 hours; 0 turns it off): past it the lane **first in the queue** treats even a live holder as breakable, kills its
  run through the same cleanup the stale breaker uses, and takes the lock.
  `winsma.sh status` (and `harness status`, when `HARNESS_WINDOWS_HOST` is set) shows the holder, how long it has held
  the lock, the heartbeat age and the queue in order with each ticket's wait; a host that does not answer within
  `WS_STATUS_TIMEOUT` (default 5 s) shows as one `winsma: unreachable` line.
- **Parking: a queued lane frees its pool slot** (#1034). Four lanes once sat in their sessions for hours, each holding a pool
  slot, polling for the lock. An **implementation lane** that has queued and is not next now runs
  `winsma.sh park <issue> <owner/repo>` (after committing and pushing; it refuses a dirty or unpushed worktree, and refuses
  when the lane is next with the lock free, in which case it should just take the lock). `park` keeps the issue's queue
  ticket, posts a `<!-- harness-handoff … -->` comment, and swaps `agent-working` for the **`waiting-winsma`** label
  (`HARNESS_LABEL_WAITING_WINSMA`) in one edit. That is not `agent-paused`: no HARNESS CHECKPOINT was sent, and the #417
  self-park nudge never looks at it. The engine reads the issue as done for its session (the session is ended, the slot is
  free) and does **not** dispatch an issue that carries the label. Each pool chores tick (at most one per
  `HARNESS_WINSMA_WAKE_S`, default 60 s, and only while an issue is parked) the engine runs `winsma.sh turn <issue>` for every
  parked issue, under `WS_WAKE_TIMEOUT` (default 20 s). `turn` refreshes the ticket, because no lane is alive to do it, so the
  place is not lost to the stale-ticket drop; it also takes a fresh ticket at the back if the old one was lost. When the
  ticket is first in the queue and the lock is free (or its holder's heartbeat is stale and the lane gone), the engine removes
  the label and the issue is dispatched once, as a resume (`resume.md`, from the pushed branch). That lane's `lock` then
  succeeds on its first attempt, ahead of any lane that queued after it. A host that cannot be reached leaves the issue parked
  (one log line per outage); with no `HARNESS_WINDOWS_HOST` configured the label is removed at once.
  **The park is an engine-owned wait (#1066).** `park` also writes the lane's wait spec (`$HARNESS_WAIT_FILE`: cond `winsma`,
  `resume=redispatch`, deadline `WS_PARK_DEADLINE_S`, default 12 h): the same spec a lane writes for a long job (`harness-wait`,
  docs/reference.md "Engine-owned waits"), judged by the same tick. Past the deadline the label is removed even if the ticket is not
  next, so a stuck queue cannot park an issue for ever; a park with no spec (older lanes) is woken by its ticket alone. The long
  `winsma.sh run` itself is started with `harness-wait run …`, and the lane ends its turn instead of polling its log.
  **The PRD review lane parks the same way** (#1038): queued and not next, it posts the Linux suite result as a PRD comment, then runs
  `winsma.sh park <prd> <owner/repo> --review`. There is no pushed branch (the review's worktree is a throwaway) and the PRD never
  carries `agent-working`, so `--review` skips the push check and only adds `waiting-winsma` to the PRD, with a
  `<!-- harness-winsma-review-park prd=N -->` comment. `check REVIEW:<prd>` reads that session as done (slot freed; the #417 nudge
  only ever looks at `agent-paused` implementation issues), dispatch skips a PRD carrying the label, and the same wake tick
  (`winsma.sh turn <prd>`) removes it when the ticket is next and the lock is free; the PRD is then re-dispatched once as
  `REVIEW:<prd>`, which reads the comments and runs the Windows suite.
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
test/smoke/winsma/winsma.sh lock 479 hz-main-i479 $PID   # or step by step (one short session, #1033): lock, isolate [--venv], guard before,
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
tasks registered), `v011` (a v0.1.1 git checkout rebuilt inside the folder, then `harness update` twice, the first printing that it must run again, the second leaving `engine -> releases/<tag>`; rolled back and forward),
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

The full suite on a Windows host (#492): `test/smoke/winsma/suite.sh` is the script a run sends
(`winsma.sh run <issue> suite "$(cat test/smoke/winsma/suite.sh)"`; the branch must be pushed). It runs in the `suite` isolation, where
`HOME` and `USERPROFILE` are `C:\hx-<issue>\home`, so no install or uninstall test can reach `C:\Users\pc`. It clones the branch, makes a
venv under the run folder whose `python.exe` is also `python3.exe` (the host's `python3` is the Store stub), and runs `bash test/run.sh`
with `PYTHONUTF8=1` (what the engine's python3 shim sets, #406) and `HARNESS_TEST_TIMEOUT` (default 600 s) per test file. It prints every red assertion with its file, run.sh's own summary
(`FAILED: <file>` lines) and `SUITE-RESULT <n> failed`; the failures Linux does not also have at the same commit are the Windows ones.
It exits 0 once run.sh has completed (`HX_STRICT=1` passes run.sh's status through), so the guard, the credential scan and the cleanup
of `winsma.sh run` still decide the run.
After run.sh it ends every process left under the run folder that is not the script's own or an ancestor of it (`reap.ps1`): tests leak
watchers that hold the ssh session's stdout open, and without this the run never returns to the claude host.

Result of the first complete runs (#492): `test/smoke/logs/suite-windows-20261106T061737Z.log` (109 of 168 files red, and the guard failed:
tests had registered five real `Harness\harness-*` Task Scheduler tasks, which led to the `schtasks` and `winget` stubs in `run.sh`), and
`test/smoke/logs/suite-windows-20261106T120731Z.log` (300 s per-file cap, `PYTHONUTF8=1`: **72 of 168 files pass, 96 red, guard clean,
no credential written, winsma clean**). The failures Linux does not have are filed as #605 (mixed `C:/` and `/c/` path spellings),
#606 (headless runner tests never reach the runner's first state), #607 (tests asserting POSIX-only mechanisms), #608 (install and
update fixtures) and #609 (gh-stub, prompt and bench tests).

What the stage provides beyond Python (#686): `jq` 1.8.1 (the tests' fake `gh` runs gh's own `-q` filters through it, and winsma has none), downloaded into the run folder
and checked against the release's sha256; a failed download is a `WARN` and the tests that need it fail. `bench/`, `issuelib.py` and `forecast.py` start `gh`, `git`, `claude`,
`harness` and `docker` through `portable.resolve_argv`, which walks PATH and PATHEXT as a shell would and runs a bash/python script (a test's fake) by its shebang: native
`CreateProcess` appends only `.exe`, so before this a fake `gh` first on PATH was skipped for the real `gh.exe` and a bench test ran against the host's GitHub account.

#605's own run, `test/smoke/logs/suite-windows-20261109T014429Z.log` (the 19 files #605 lists, 600 s cap, branch `issue/605` at the
one-spelling-per-directory fix): **8 of 19 pass**; test_path_split, test_submodule, test_worker, test_fleet_registry, test_bypass,
test_spawn, test_stats.py and test_supervise_rules.py are green. The other 11 were read from that log and fixed in the tests or the hermes
liveness check afterwards (the opencode plugin driver `import()`s a file URL, copilot's lock is the `mkdir` mutex, hermes' `os.kill(pid, 0)`
is `portable.pid_alive`, forecast runs Git's bash, the pre-release fixture keeps `.gitattributes`); they are not re-run on winsma yet.
The full 19-file run, `test/smoke/logs/suite-windows-20261110T121159Z-605-19files.log` (1500 s cap): **11 of 19 pass**. The red ones: the five adapter files
(codex, copilot, hermes, openclaw, opencode) pass every assertion of their own and then time out in the closing `test_cli_matrix.sh --tsv`
call for their CLI, which takes more than 25 minutes on this host (`HARNESS_MATRIX_TIMING=1` prints each cell's seconds); `test_fleet_migrate.sh`
hung once at a `harness start` in its last third (it passed in the run before); openclaw's hangup-ends-the-tree case is still red; and two tests
main added since (`test_stats.py`, `test_forecast.py`: Git's bash instead of WSL's, and the Windows "Invalid argument" for a form feed in a file name)
were fixed afterwards. Those fixes are not re-run on winsma.
The last runs (11 Nov, branch `issue/605` then `main`): `test_stats.py` green, `test_fleet_migrate.sh` 182 of 182, `test_cli_openclaw.sh` passes every assertion of its
own, the hangup case included (`proc_kill_tree` also signals the MSYS descendants it reads from `/proc`: `taskkill /T` follows Windows parents, and
an MSYS fork or exec leaves a child whose Windows parent is gone), and `test_forecast.py` green in `test/smoke/logs/suite-windows-20261111T164624Z-605-forecast.log`
(a form feed cannot be in a Windows file name, and the `--bodies` error quotes the path as the caller spelled it). Those runs were cut short several
times by other lanes releasing an "idle" holder (#1062); copying `suite.out` to the lane's side every 90 s kept the evidence. The adapter files'
matrix time is the follow-up issue's.
The five adapter files again, `test/smoke/logs/suite-windows-20261111T164124Z-1028-5adapters.log` (#1028; branch `issue/1028` at `aeb13d2`,
`HARNESS_MATRIX_TIMING=1`, 1500 s cap): **3 of 5 pass, the whole run 3220 s (54 min), guard clean, winsma clean.** codex, hermes and opencode are
green. The two reds are not timeouts and were never seen before, because no run reached their last assertions: copilot's `headless-send` matrix
cell (#1073) and openclaw's hangup-ends-the-tree case, which the `proc_kill_tree` fix above makes green on `main` (this run predates it). What the timing showed:
the CLIs' cells are computed in the prefetch, in parallel, one CLI per child; a CLI's cells took, serially, codex 1971 s (53 cells), copilot 2143 s
(61), hermes 2173 s (51), openclaw 1923 s (49) and opencode 887 s (48), so the prefetch is bounded by the slowest CLI, about 50 minutes
(it ended between 16:34 and 16:39, run.sh started 15:46); the five files together then took under 6 minutes, each well inside the 1500 s cap.
Before this run the same files recomputed their CLI's cells after the prefetch (codex printed 106 `matrix-timing` lines for its 53 cells, on Linux
too): `test_cli_matrix.sh`'s cache key carried the starting `PATH`, and every adapter test prepends scratch stub dirs of its own, so none of them ever
hit the prefetch's entry. The key now leaves out the `PATH` entries under the run's `TMPDIR`. Three earlier runs of these files on this host were cut
short before a verdict (a pre-#1033 branch against the FIFO lock, then the idle-holder release of a `run`, fixed in #1062): a run that needs more
than an hour should be started on a branch rebased onto `origin/main`.
`HX_VERBOSE=1` makes `suite.sh` print run.sh's whole output (`| `-prefixed) after the summary, to read why a red file is red.

copilot's `headless-send` cell on winsma (#1073): the one red the five-adapter run above left that was not a timeout does not reproduce on `main` (`62d9257`, which carries the
`proc_kill_tree` fix of #1071 and the cache-key fix of #1076). Five runs in the suite isolation, `HARNESS_MATRIX_TIMING=1`, each with the cell's step-by-step diagnostics in
place (they never fired, and were removed again): the cell alone (`HARNESS_MATRIX_CLIS=copilot HARNESS_MATRIX_ROWS='^headless-send$'`, 26 s, ok); the `headless-*` rows of codex,
copilot, hermes, openclaw and opencode in parallel as the suite's prefetch runs them (33 s, ok); the whole matrix of those five CLIs (53/53, 53/53, 51/51, 49/49, 48/48, ok;
a first attempt was lost to an ssh drop 38 min in); and the acceptance run, `HX_TESTS="test_cli_codex.sh test_cli_copilot.sh"`, `test/smoke/logs/suite-windows-20261112T004703Z-1073-copilot.log`:
**`test_cli_copilot.sh` 70/70 and `test_cli_codex.sh` 67/67, guard clean, winsma clean, 29 min.** The cell's own timeouts are scaled 8x on Windows (`hl_wait`) and it took
25-37 s each time, so it was not near a limit. What turned it red at `aeb13d2` is not known: that run predates #1071 (leftover MSYS descendants of a fake agent that `taskkill`
could not name), which is the likeliest cause, but no run could show it. If it comes back, run the five-CLI matrix again and read the cell's own output.
The matrix cells that were red by host load (#944: `agy: headless-resume`, `hermes: stats-session-end-usage`, `hermes: headless-loop-mode`, `hermes: headless-stats-session-end-usage`,
`openclaw: review-gauntlet`, `openclaw: headless-stats-session-end-usage`) do not reproduce on `main` (`2c3f46f`). Two runs in a row in the suite isolation, `HX_TESTS=test_cli_matrix.sh`
`HARNESS_MATRIX_CLIS='agy hermes openclaw' HARNESS_MATRIX_TIMING=1`: **agy 53/53, hermes 51/51, openclaw 49/49 both times**, `run.sh` 81 min and 69 min, guard clean, `reap.ps1` found
nothing, winsma clean after (`test/smoke/logs/suite-windows-20261112T055407Z-944-matrix-run1.log`, `...T074045Z-944-matrix-run2.log`). `hl_wait`'s 8x Windows scaling (#1073) and the `proc_kill_tree` fix (#1071) landed after the red runs and are the likeliest cause of the change (not shown: no run isolates them). If a cell goes red again, rerun it with
`HARNESS_MATRIX_ROWS='^(row)$'` and `bash -x` and read its own output; a host-load red has no code cause to fix in the test.
The headless twins of the tmux tests (#493): `HX_TESTS="test_watchdog_headless.sh …"` makes `suite.sh` run just those files
(`bash test/run.sh <files>`) in the same isolation. Their winsma logs are `test/smoke/logs/suite-windows-20261106T*.log`; the last,
`suite-windows-20261106T225957Z.log`, has `test_watchdog_headless.sh`, `test_env_leak_headless.sh` and `test_session_names_headless.sh`
green and `test_sess_sweep_headless.sh` with one red assertion (a job without the lane's `HARNESS_SESSION`, left by a turn whose
parent exited, outlives `sess_kill`: Windows has no process groups). Two traps these runs found: a path handed to a command line a
native Python builds itself must be in native form (`native_path` in `test/helpers.sh`; `/c/x` is read as `C:\c\x`), and a shebang
script is not runnable by a native process, so the fake claude's `turn-hook` goes through bash there. What is still red is #627.

`test/test_winsma.sh` covers all of it on Linux with a fake ssh, a fake `C:` drive, a fake Task Scheduler and a fake
process list: the host itself is only touched by a recorded run
(`test/smoke/logs/winsma-helpers-windows-20261104T013238Z.log`: the whole sequence with a trivial command, winsma clean after;
`test/smoke/logs/windows-installer-windows-20261104T041438Z.log`, #488: `install.sh` with a `HARNESS_WINGET` stub, `harness init`, `harness start` dispatching an issue, doctor green, guard clean;
`test/smoke/logs/task-names-windows-20261104T085249Z.log`, #489: two `HARNESS_HOME`s installed side by side get distinct, logon-only supervise and web tasks, removing one leaves the other, guard clean). **Developer Mode is off on winsma**: symlinks work
there only because the ssh session is an elevated administrator, so the non-admin path is covered by the
`HARNESS_PLATFORM=windows` fakes, not by a live run.

Knobs: `WS_POLL` (wait between lock polls, default 300 s; a lower value is clamped to 300, `WS_POLL_MIN` is the test seam), `WS_IDLE_MAX` (how long an idle holder keeps the lock, default 600 s), `WS_STALE_SEC` (default 1800), `WS_HOLD_MAX` (hold cap, default 5400 s), `WS_HOLD_HARD` (hard ceiling, default 3 × `WS_HOLD_MAX`, 0 = off), `WS_STATUS_TIMEOUT` (default 5 s), `WS_LOCK_TIMEOUT` (default
0 = wait as long as it takes), `WS_HB_INTERVAL` (default 300 s), `WS_LANE_SESSION` / `WS_LANE_PID` (what `lock` records
as the owner; pid defaults to the caller's parent).

### The end-to-end record of PRD #475 (#496)

Every claim in the [parity matrix](reference.md#windows-parity-matrix) names the log that shows it. The runs of the last task, each under the rules
above (lock, isolation, guard before and after, credential scan, cleanup; every log opens with the host, the commit and its Claude token usage):

| What | Script | Log |
|---|---|---|
| The live `claude` smoke: claim → lane → PR → merge → close, `pause --force` and resume, then the lane's token usage from `harness stats` and `harness forecast` (the only run with the real Claude sign-in) | `winsma.sh run <n> base`, `e2e.sh` stage `live` | `test/smoke/logs/live-claude-windows-20261112T125158Z.log` |
| Install by `npx` and by `curl`, re-install, update from v0.1.1 and from the previous release, rollback and forward, `uninstall --force --force-engine` | `lifecycle.sh` | `test/smoke/logs/lifecycle-windows-20261112T114048Z.log` |
| `update --with-skills` into the sandbox `CLAUDE_CONFIG_DIR`, every `/harness*` skill linked, a lane-shaped shell | `tooling.sh` | `test/smoke/logs/tooling-windows-20261112T120058Z.log` |
| `supervise --install`, a killed worker restarted by the supervisor, `supervise --uninstall` | `e2e.sh` stage `supervise` | `test/smoke/logs/e2e-windows-20261112T094302Z.log` |
| the dashboard (foreground and its task), `stats`, `forecast`, `one`, `status`, `poll`, `migrate`, `tier`, `release --dry-run`; `plan`, `prd` and `issue` | `e2e.sh` stages `ops`, `inject` | `test/smoke/logs/e2e-windows-20261112T094302Z.log` |
| the fixture-replay `headless-*` rows of every CLI, on Windows | `suite.sh` with `HX_TESTS="test_cli_matrix.sh"` | `test/smoke/logs/suite-windows-20261112T131219Z-496-cli-matrix.log` |
| the other CLIs, live and headless, on the claude host | `fleet_smoke.sh <cli>` with `SMOKE_BACKEND=headless`; `codex_headless_smoke.sh` | `test/smoke/logs/<cli>-headless-20261108T*.log`; re-run at v0.13.3 with each lane's token usage logged (`test/smoke/lane_usage.sh`), copilot, opencode, hermes, openclaw and agy: `test/smoke/logs/<cli>-headless-20261113T150912Z.log` |

Three things those runs showed that the guide above would not tell you:

- **Task Scheduler needs a logged-on user for these tasks.** `supervise --install` and `web --install` register `InteractiveToken` tasks that
  start at the task user's logon and run in that user's session (no administrator, nothing at boot). On winsma the ssh session is an administrator
  but the task user, `pc`, has no interactive session (`quser` lists another user on the console), so `schtasks /Run` queues the task and it never
  starts: `Last Result` stays `267011`, "the task has not yet run". The record therefore starts the task's own command line (`bash.exe` and the
  launcher script it names, exactly the task's `<Exec>`) detached, and says so. On a desktop where the owner is logged on the task runs itself, and
  a task that cannot start shows in `schtasks /Query /TN <name> /V /FO LIST`.
- **A supervisor pass is slow on Windows.** Every `gh`, `python3` and `git` call is a process spawn, so one pass over a fleet takes minutes, and a
  worker killed just after a pass began is restarted by the pass after it. The record allows 15 minutes.
- **A native Windows Python writes CRLF into a pipe.** Any `python3 … | while read` in the engine sees a trailing `\r`; the supervisor strips it
  (#496), and new code that reads Python's output in bash must do the same.

**Checkpoint on a fast lane.** The headless smokes ran with the checkpoint step on where the lane took long enough to be caught mid-task
(`opencode`), and off where a lane finished its one-file task before the pause could land (`copilot`: 100 s from launch to merge, so `pause --force`
waited out its 15 minutes for a lane that no longer existed, #662). `agy` ran on its Gemini model because its Claude-and-GPT bucket was at 100% until
Wed 08:01 UTC.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `uname -s` prints `Linux` | you are in WSL's bash: open Git Bash, or start `"C:\Program Files\Git\bin\bash.exe"` by path |
| `Python was not found; run without arguments to install from the Microsoft Store` | the Store stub: install Python (step 1), re-run `bash install.sh` for the shim, or set `HARNESS_PYTHON` |
| `$'\r': command not found` | a CRLF engine: re-clone (the `.gitattributes` keeps it LF), or `git config --global core.autocrlf false` and re-clone |
| `ln -s` made a copy, or doctor says `symlinks: cannot create one` | turn on Developer Mode, or run as an administrator |
| `fleet_smoke: native Windows has no tmux` | unset `SMOKE_BACKEND`, or set it to `headless` |
| `fleet_smoke: '<cli>' is tmux-only` | the name is not a CLI with a headless lane runner (`agy`, `claude`, `codex`, `copilot`, `hermes`, `openclaw`, `opencode`): check the spelling |
| `fleet_smoke.cmd: no Git bash.exe at …` | Git for Windows is elsewhere: set `HARNESS_BASH_EXE` to its `bin\bash.exe` |
| the issue never gets claimed | read `harness doctor`'s `windows:` lines in the log, then `harness --state-dir <clone>/.harness status` while it runs |
| `install.sh`: `could not resolve the latest release … the response is not JSON` | an `install.sh` from before #403's fix ran the releases lookup with the Store-stub `python3` before the shim existed; a current one resolves it through the Python that runs and writes the shim first. On an older one: `HARNESS_REF=<tag> bash install.sh` (e.g. the latest from `gh release list -R VocanicZ/Harness`) |
| `harness start` exits with `install Python 3, then re-run install.sh/harness update for the shim, or set HARNESS_PYTHON` | no working `python3` (the Store stub, no shim): start refuses, since the fleet could never claim an issue (#405). Fix the install (above), then check `~/.harness/bin/python3 --version`. An engine from before #405 starts anyway and its worker log fills with `Python was not found…` |
| `checkpoint not confirmed: issue #N is not agent-paused`, the lane's screen is empty | Windows Python's cp1252 stdio breaks the headless lane's screen, so the stuck-turn interrupt never fires (#406): `export PYTHONUTF8=1` before the smoke |
