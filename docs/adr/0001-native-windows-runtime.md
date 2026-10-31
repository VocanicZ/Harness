# ADR 0001: Native-Windows runtime: Git Bash plus targeted replacements

- **Status:** accepted, 2026-10-31
- **Issue:** #348 (part of PRD #344)
- **Follow-ups:** #355, #356, #357, #358 (see [Follow-up work](#follow-up-work))

## Context

PRD #344 asks for Harness on native Windows, with no WSL. Lanes run on the headless session backend
(#346 seam, #347 runner, #349 backend) in place of tmux panes. The rest of the engine is about 8,200
lines of bash (`bin/harness`, `scripts/*.sh`, `scripts/cli/*.sh`, `install.sh`, `update.sh`) and
4,800 lines of Python (`scripts/*.py`). It also uses `/proc`, `flock`, systemd user units and other
Linux-only tools. This ADR picks the smallest way to run that engine on Windows, lists every
Linux-only dependency it has, and names the replacement for each one.

PRD constraints: Linux/tmux behaviour stays the same by default; no GitHub Actions (#245); **no new
runtime dependency on Linux**.

### What a Windows host has (measured)

On 2026-10-31 we probed winsma, the Windows machine #358 runs the smoke on, over `ssh winsma`:

| | |
|---|---|
| OS | Windows 10, `10.0.19045.6456` |
| Git for Windows | bash `5.3.15(2)-release`, `MINGW64_NT-10.0-19045 3.6.10 … Msys` |
| Present in Git Bash | GNU `stat`, `date`, `sed`, `awk`, `readlink`, `realpath`, `ps` (MSYS), `timeout`, `xargs`, `sort`, `base64`, `sha256sum`, `md5sum`, `tac`, `mktemp`, `nohup`, `tput`, `tar`, `curl`, `cygpath`; GNU flags `stat -c %Y`, `date -d @0`, `date -d <ISO>`, `readlink -f`, `realpath -m`, `base64 -w0`, `sort -V`, `mv -T` all work |
| **Missing** in Git Bash | `flock`, `setsid`, `pgrep`, `pkill`, `uuidgen`, `fuser`, `lsof`, `tmux` |
| `ps` | MSYS `ps`: `ps -e -o pid=,ppid=` fails with `ps: unknown option -- o`; `ps -W` lists Windows processes |
| `/proc` | MSYS emulation: lists only MSYS processes; `/proc/<pid>/{cmdline,environ,ppid,winpid,fd}` exist; no `/proc/sys/kernel/random/uuid` |
| `ln -s` | by default makes a **copy**: `ln -s r l` creates a directory `l`, not a link. With `MSYS=winsymlinks:nativestrict` it makes a real symlink |
| Python | native CPython 3.13.5 (`win32`); `import fcntl` fails with `ModuleNotFoundError`; `msvcrt.locking` exists. `python3` on `PATH` is the Microsoft Store stub (`Python was not found; run without arguments to install from the Microsoft Store…`); the real interpreter answers to `python` |
| `bash` on the cmd `PATH` | `C:\Windows\System32\bash.exe`, which is **WSL's** bash, not Git's |
| git | `core.autocrlf=true` in `C:/Program Files/Git/etc/gitconfig` (the installer's default) |
| Also present | `taskkill`, `tasklist`, `schtasks`, `powershell`, Node `v26.13.0`, Claude Code `2.1.314` |

So most of the "GNU-only flag" worry does not apply: Git Bash ships GNU coreutils. The gaps are
locking, process discovery, process trees, service management, symlinks, the Python interpreter
and line endings.

## Decision

**Run the engine as it is under Git Bash (Git for Windows, MSYS2 runtime) with native Windows
CPython, use the headless session backend, and add a small set of portable helpers that pick the
Windows path when `uname -s` reports `MINGW*`/`MSYS*`.** Linux runs the same code it runs today:
each helper's Linux branch is the current implementation, moved behind a function.

1. **Lanes:** `HARNESS_SESSION_BACKEND=headless` is required on Windows. tmux is never needed, and
   `harness doctor` / `start` refuse `tmux` there (#356).
2. **Locks:** `lock_acquire` / `lock_try` / `lock_release` / `lock_holders` replace the
   `exec {fd}>f; flock fd` pattern. Linux keeps `flock` and its fd semantics. Windows takes an
   atomic `mkdir "$f.d"` with an `owner` file (MSYS pid, winpid, cmdline). A waiter steals a lock
   whose owner pid is dead (`kill -0`), and `lock_holders` reads `owner` instead of scanning
   `/proc/*/fd`. `stats.py` uses `fcntl.flock` on Linux and `msvcrt.locking` on Windows (#355).
3. **Processes:** one `proc_find <regex>` helper scans `/proc/[0-9]*/cmdline` in bash. That works
   on Linux and in MSYS alike, so `pgrep` goes away on both and no Windows branch is needed.
   `/proc/<pid>/environ` reads stay as they are, because the pool and priority workers are MSYS bash
   processes and MSYS exposes their environment. Python's `os.kill(pid, 0)` probes go through a
   `pid_alive` helper. On Windows that helper uses `OpenProcess` + `GetExitCodeProcess` (ctypes,
   stdlib) on the winpid recorded beside the pid (#355).
4. **Process trees:** to kill a headless lane's turn, run `taskkill //T //F //PID <winpid>`, with the
   winpid read from `/proc/<pid>/winpid`. On Linux the kill stays POSIX (process group or a
   `/proc`/`ps` tree). Supervisor liveness for headless lanes comes from the runner's state and
   events (#347, #351), not from `ps -eo …,cputimes=`, so `sup_tree_cpu` stays tmux/Linux-only.
5. **Lifecycle:** Task Scheduler replaces systemd user units. `supervise --install` and
   `web --install` register an `ONLOGON` task (`schtasks /Create`) that runs Git's `bash.exe` by
   absolute path. `harness start` launches workers and the poller detached from the calling
   session, through a scheduled task or `powershell Start-Process`, and records pid files.
   Processes `nohup`'d from an OpenSSH session die when that session ends (#356).
6. **Install/update:** `install.sh` / `update.sh` run under Git Bash. On Windows they set
   `MSYS=winsymlinks:nativestrict` so the engine link is a real symlink, and `doctor` proves a
   symlink can be created (Developer Mode or admin). They also put a `python3` shim in
   `$HARNESS_HOME/bin` that execs the configured interpreter (`HARNESS_PYTHON`, default the first
   of `python3`/`python`/`py -3` that actually runs). A `.gitattributes` keeps engine scripts LF
   (#356).
7. **Paths:** engine variables read by native executables (`python.exe`, `gh.exe`, `claude.exe`)
   are exported in mixed form (`cygpath -m`, `C:/…`) on Windows. MSYS converts argv for native
   programs but not arbitrary environment variables (#355).

New dependencies are **Windows-only**: Git for Windows and a native Python 3. The Linux dependency
set (`git tmux python3 curl sha256sum tar`) does not change.

## Alternatives weighed

| | A. Git Bash + targeted replacements (**chosen**) | B. Port the dispatch loop to Node | C. Port the dispatch loop to Python | D. Full MSYS2 / Cygwin with packages |
|---|---|---|---|---|
| What | Same bash + Python engine; about 10 helpers gain a Windows branch | Rewrite claim, drive, pool, poller, supervisor, start/stop (the ~2,800 lines of `lib.sh`, `drive.sh`, `pool-worker.sh`, `supervise.sh` and their callers) in Node, the way MorphEdit/Hx did | Same rewrite into the Python the engine already ships | Install MSYS2 and `pacman -S util-linux procps-ng tmux` for a Linux-like userland |
| Effort | Small to medium: the helpers plus a guard test (#355), lifecycle (#356), smoke (#357) | Large: two engines, or a full rewrite of the Linux one. 56 of 105 test files `source lib.sh` and would need porting | Large, for the same reasons; less glue than Node | Small for flock/pgrep/ps; tmux under MSYS2 still cannot host native `claude.exe` panes, so the headless backend is needed anyway |
| Risk | Low on Linux (each Linux branch is today's code); Windows risks are named and confined to helpers | High: behaviour drift between two loops, or a rewrite that has to re-learn every fix in the git log (#179-#340) | High, same drift/rewrite risk | Medium: MSYS2 is a large unpinned install; `pacman` versions drift; little gain over A |
| No new Linux runtime dependency | ✓ | ✗ if one Node loop serves both platforms (Node becomes a Linux dependency); ✓ only by keeping two loops | ✓ (Python already required) | ✓ (Windows-only) |
| Windows prerequisites | Git for Windows, Python 3, gh, claude | Node ≥ 23.6, git, gh, claude | Python 3, git, gh, claude | MSYS2 + packages, Python 3, gh, claude |

**Why A.** It is the only option that keeps one engine and adds nothing on Linux. It also leaves the
existing suite as the safety net for the Linux path. The probe shows Git Bash already supplies the
GNU userland the engine assumes. What remains is a short list of primitives with known Windows
equivalents: `mkdir` locks, `msvcrt.locking`, `taskkill /T`, `schtasks`, native symlinks.

**Why not B, even though it is proven.** [MorphEdit/Hx](https://github.com/MorphEdit/Hx) is the
prior art. It drives `claude -p --output-format stream-json` from Node, with no tmux and no screen
scraping, and it runs on plain Windows. It shows the *lane* model works on Windows. Harness takes
that part through the headless backend (#347/#349). Hx was written for Windows from day one. For
Harness, a Node dispatch loop means either a second engine to keep in step with every
claim/drive/supervise fix, or Node as a new Linux runtime dependency, which the PRD forbids. Moving
only the lanes, as Hx does, gets the Windows benefit without porting the loop.

**Why not C.** It would be acceptable on dependencies, but it costs as much as B and adds no
Windows capability that A lacks.

**Why not D.** It solves `flock`/`pgrep`/`ps -o` but none of the hard parts: native `claude.exe` in
a pane, systemd, symlinks, line endings. It also adds a heavy install. A's helpers are needed anyway.

**WSL** is out of scope: the PRD says no WSL.

## Dependency inventory

Every Linux-only dependency in the engine (`bin/harness`, `scripts/`, `install.sh`, `update.sh`)
as of `219444a`, how Git Bash on Windows handles it, and what replaces it there.
`test/test_windows_runtime_doc.py` fails if the engine uses a primitive this table does not name.

| Dependency | Where the engine uses it | On Windows (Git Bash, measured) | Replacement on Windows | Issue |
|---|---|---|---|---|
| `tmux` | lane lifecycle, `capture-pane`, `#{pane_pid}`, `tmux ls` in 23 files (`lib.sh`, `drive.sh`, `supervise.sh`, `stop.sh`, `status.sh`, `attach.sh`, `pause.sh`, `turn.sh`, `usage.sh`, `web*.py`, `fleetview.py`, `cli/*.sh`) | absent | the headless session backend behind the #346 seam; `tmux` backend refused on Windows | #346, #349, #351, #352 |
| `/proc/<pid>/environ`, `/proc/<pid>/cmdline` | `proc_state_dir`, `proc_engine_dir`, the live-worker guard (`lib.sh`), `install.sh` / `uninstall.sh` live-release checks | present for MSYS processes (the workers are MSYS bash) | kept; reads go through the #355 helpers, so a native process never has to be found this way | #355 |
| `/proc/*/fd` scan | `lock_holders` (`lib.sh`), `doctor.sh` start-lock wedge check | present, but holds no `flock` fds | `lock_holders` reads the Windows lock's `owner` file | #355 |
| `/proc/sys/kernel/random/uuid` | `lib.sh` uuid fallback after `uuidgen` | both absent | `python3 -c 'import uuid; print(uuid.uuid4())'` as the last fallback | #355 |
| `flock` (shell) | about 25 sites in 11 files: claim locks (`claim_next`, `claim_bug`), registry and cache locks, `start.sh` fd-9 double-start lock, `lock_free`, poller, usage, autorelease, the CLI trust-file locks | **missing** | `lock_acquire` / `lock_try` / `lock_release`: Linux `flock`; Windows atomic `mkdir <lock>.d` + `owner` file, stale owner stolen | #355 |
| `fcntl.flock` (Python) | `stats.py` event append | **no `fcntl` module** | `msvcrt.locking` on byte 0, same non-blocking retry for `LOCK_WAIT_S` | #355 |
| `pgrep` / `pkill` | `pgrep -f` in the live-worker guard (`lib.sh`) and `uninstall.sh`; `pkill` appears only in a comment (and is banned by the shared-host rule) | **missing** | `proc_find <regex>`: a bash `/proc/[0-9]*/cmdline` scan, the same on Linux and MSYS | #355 |
| `ps -eo` | `sup_tree_cpu` (`supervise.sh`), the `tree()` helpers in `cli/openclaw-loop.sh` / `cli/openclaw.sh`, the POSIX branch of `kill_tree` in `cli/claude_headless.py` (#347; its Windows branch is `taskkill /T /F`) | MSYS `ps` has no `-o` | headless lanes report liveness through runner state/events (#351), so `sup_tree_cpu` stays tmux-only; a `/proc/<pid>/ppid` tree helper for MSYS trees; openclaw is tmux-only (n/a on Windows) | #355, #351 |
| `setsid` / process-group kill | not used today; the headless runner needs a kill that ends the turn's whole tree | **missing**; MSYS signals do not reach native children | `taskkill //T //F //PID <winpid>` (`/proc/<pid>/winpid`) | #347, #349, #355 |
| `kill -0` (shell) | 21 pid-liveness checks in 13 files | works for MSYS pids | kept; pid files hold MSYS pids, and native children are tracked by the runner | #355 |
| `os.kill(pid, 0)` (Python) | `pid_alive` in `fleetview.py` and `web_data.py`; `cli/hermes.sh` | **wrong**: on Windows signal `0` is `CTRL_C_EVENT`, and the pid is an MSYS pid, not a Windows one | `pid_alive` helper: `OpenProcess` + `GetExitCodeProcess` via ctypes on the recorded winpid; hermes is tmux-only | #355 |
| `trap … TERM` | `cli/openclaw-loop.sh`, `status.sh` watch | MSYS-to-MSYS only | the runner stops its turn with the `taskkill /T` path above; `status.sh`'s trap is cosmetic | #347, #355 |
| `nohup … &` | `pool.sh`, `priority.sh`, `ensure_poller` (`lib.sh`) | present, but a process started from an OpenSSH session dies with that session | detached launch through a scheduled task or `powershell Start-Process`, with pid files | #356 |
| `systemctl --user` / `loginctl enable-linger` | `supervise.sh --install`, `web.sh --install`, `uninstall.sh` | absent | Task Scheduler: `schtasks /Create /SC ONLOGON` running Git's `bash.exe` by path; uninstall deletes the task | #356 |
| `stat -c` | `lib.sh` grace-mark age, `cli/dispatch.sh` cache age | present (GNU coreutils) | none needed | none |
| `date -d` | `supervise.sh`, `ghrate.sh`, `usage.sh`, `lib.sh` | present, including ISO and `@epoch` | none needed | none |
| `readlink -f` / `realpath -m` | `bin/harness` self-location and `canon`, `lock_holders` | present; returns MSYS paths (`/c/…`) | none for bash; see paths below | #355 |
| `mv -T` | `install.sh` / `update.sh` release placement and the engine-link flip | present | none for the command; whether renaming over a directory symlink is atomic must be verified on winsma | #356 |
| `ln -s` / `ln -sfn` | the `install.sh` engine link (`$HARNESS_HOME/engine` → `releases/<tag>`), skill links | **copies silently** by default | `MSYS=winsymlinks:nativestrict` in install/update; `doctor` proves a symlink can be made (Developer Mode or admin) | #356 |
| other GNU coreutils: `sort -V`, `base64 -w0`, `tac`, `sha256sum`, `md5sum`, `xargs -r`, `mktemp`, `timeout`, `tput`, `cp -al --parents` | `release.sh`, `seed.sh`, `install.sh`, `turn.sh`, `supervise.sh`, `uninstall.sh`, `status.sh`, `swarm-suite.sh` | present | none needed (swarm is off on Windows: `HARNESS_SWARM=off`) | none |
| `chmod +x` | `cli/claude.sh` (the ralph-loop hook), `install.sh` | no-op on NTFS; MSYS runs a shebang `.sh` anyway | none for bash. Whether Claude Code on Windows runs a `.sh` Stop hook (through Git Bash) must be checked in the smoke; the headless runner's driven loop does not need the hook | #357, #358 |
| `python3` | 112 call sites in 30 files | the `python3` on `PATH` is the **Microsoft Store stub** | a `python3` shim in `$HARNESS_HOME/bin` that runs `HARNESS_PYTHON` (probed: the first of `python3`/`python`/`py -3` that runs); `doctor` runs it | #356 |
| `bash` | every entrypoint (`bin/harness`, `#!/usr/bin/env bash`) | `C:\Windows\System32\bash.exe` on the cmd `PATH` is **WSL** | entrypoints (scheduled tasks, a `harness.cmd` shim, the runbook) name Git's `bash.exe` by absolute path; `doctor` checks that `uname -s` starts with `MINGW` or `MSYS` | #356, #357 |
| line endings (LF) | every engine script | `core.autocrlf=true` system-wide: a git-clone engine gets CRLF, and bash fails on `$'\r'` | a `.gitattributes` with `eol=lf` for scripts; release tarballs already keep LF | #356 |
| path form (`/c/…` vs `C:\…`) | `STATE_DIR`, `RUN_DIR`, `HARNESS_HOME` and friends, read by native `python.exe` / `gh.exe` / `claude.exe` | MSYS converts argv for native programs but not these variables | on Windows, export the variables native programs read in mixed form (`cygpath -m`) | #355 |
| `install.sh` prerequisite list | `git tmux python3 curl sha256sum tar` | `tmux` absent, `python3` a stub | the Windows list is Git for Windows, Python 3, `gh`, `claude`, `curl`, `tar`; `tmux` is not required with `headless` | #356 |
| `update.sh` | release download, `SHA256SUMS` verify, extract, engine-link flip, prune, `--rollback` | download/verify/extract work as on Linux | the symlink and `mv -T` items above; otherwise unchanged | #356 |

## Follow-up work

The decision maps onto the PRD's existing sibling issues. No new issue is needed; where a sibling's
scope grows, the amendment is posted as a comment on #344 and on that issue.

| Issue | What this decision gives it |
|---|---|
| #346, #347, #349 (seam, runner, backend) | Unchanged. #347's "writable so it can later run on native Windows" means: the runner's core path uses none of `/proc`, `flock` or `setsid`. Its tree-kill goes through the #355 helper, so on Windows it is `taskkill /T` |
| #355 portable primitives | Implements the lock, `proc_find`, `pid_alive`, tree-kill and uuid helpers above, the `msvcrt` branch in `stats.py`, and mixed-form path export, behind a guard test with a reasoned allowlist. **Amended:** the Python-side items (`fcntl`, `os.kill(pid, 0)`) and path form are in scope |
| #356 lifecycle / install / update / doctor | Implements Task Scheduler in place of systemd, detached launch, the `python3` shim, `winsymlinks:nativestrict`, `.gitattributes` and the Windows prerequisite list. `doctor` checks Git's bash, a working Python, symlink creation and `HARNESS_SESSION_BACKEND=headless`. **Amended:** the shim, the WSL-`bash.exe` check, `.gitattributes` and the symlink check are in scope; it also verifies on winsma that renaming over the engine link is atomic |
| #357 smoke tooling + runbook | The runbook installs Git for Windows and Python 3, enables Developer Mode (symlinks), and runs everything through Git's `bash.exe` by path, never the cmd-`PATH` `bash` |
| #358 the winsma run | Checks the two items left open here: `mv -T` over a directory symlink, and processes surviving the end of the ssh session under the #356 launch. It also checks whether Claude Code runs the `.sh` Stop hook on Windows. Each failure is filed as its own issue |
| #351, #352 (supervisor, usage/stats on headless) | Unchanged: they read runner state, not panes or `ps` CPU, which is what makes `sup_tree_cpu` unnecessary on Windows |

## Consequences

- Linux runs the code it runs today, behind helpers. The existing suite guards it, and #355's
  guard test keeps new raw `flock` / `/proc` / `pgrep` uses from creeping back in.
- Windows support depends on Git for Windows' MSYS runtime, a widely installed and stable target,
  plus a native Python. Neither is needed on Linux.
- Only `claude` lanes run on Windows, since they are the only headless lanes. The other CLIs stay
  tmux-only, as #349 and #353 mark.
