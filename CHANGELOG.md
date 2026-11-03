# Changelog

Notable changes to Harness. Releases and their full notes: [GitHub Releases](https://github.com/VocanicZ/Harness/releases).

## Unreleased

### `harness one done` and HARNESS_ONE_AUTO skip an issue a live lane still owns (#446)

- `issuelib next` skipped only `--exclude`, while dispatch also skips the issues a live lane still owns
  (`busy_issues_for`, #416). A checkpointed lane keeps its worktree after it drops `agent-working`, and
  `next` puts `agent-paused` issues first, so under a hold it often offered that very issue:
  `harness one start` then failed ("worktree add failed … claim released"), and `one_auto_tick` picked
  it every poll, failed to spawn it and never moved on.
- `harness one done` and `one_auto_tick` now pass `busy_issues_for` through `issuelib next --exclude`:
  they offer / start the next claimable issue nobody owns, or none. test_one_run.sh, test_one_auto.sh.

### `harness one phase` sees the interactive session's own spend (#445)

- On the claude adapter the per-phase re-check read only status-line drops and this fleet's headless
  lanes. The interactive `/harness-one` session runs no Harness status line, and a paused or held fleet
  renders none, so `now%` stayed frozen while the forecast left shrank: the checked value fell phase by
  phase and the stop % was never reached mid-issue. A reading past its `resets_at` was dropped, leaving
  the window unchecked.
- `harness one phase` now adds what the reading's account spent since the reading was taken — its
  Claude transcripts (main and sub-agents, each message once), priced at list price, over the window's
  $ per 1% (the #364 bound, else `HARNESS_ONE_USD_PER_PCT`). `harness one start` keeps the readings it
  saw (`run/one/<unit>-i<n>.start`, removed by `release` and the reaper), so a window that reset since
  is checked from 0% at the reset plus the spend since, and one gone without a reset as it was read.
- It fails closed: a reading that is not current (from before `start`, stale, of unknown age, or gone
  since `start`) whose spend cannot be counted is a CHECKPOINT (`usage stale`), never a silent FITS.
- `test/test_one_run.sh`: with no usage stub, a frozen status-line drop and the session's spend written
  as Claude Code transcripts, `phase` goes FITS → FITS → CHECKPOINT without the drop being touched; a
  window reset since `start` is checked from 0%; both CHECKPOINT when the spend is uncountable.
  `test/test_one.py`: the spend arithmetic, the restored windows, the fail-closed cases, and
  `account_spend_since` on a fixture config dir.

### `test_hermetic.sh`'s update.sh scan no longer misses tests at random (#441)

- `runs_update` piped `grep -v` into `grep -q` under `set -o pipefail`. `grep -q` quits at its first
  match; when `grep -v` still had a write pending (non-comment text over one pipe write), that write
  took SIGPIPE, `grep -v` exited 141, and the scan read false. On one CPU it missed
  `test_web_install.sh` (8/300) and `test_supervise.sh` (5/300): the suite went red at random
  (`FAIL: the update.sh scan finds test_web_install.sh`), and a missed test outside the must-find list
  silently ran without its decoy home and curl tripwire (#434).
- The reader now drains its input (`grep -E … >/dev/null`), so the pipeline's status is the match.
  Both files are found 300/300 under `taskset -c 0`.
- `test/test_hermetic.sh`: a fixture whose match sits in the first 4 KiB of >8 KiB of non-comment text
  is found 300/300 (pinned to one CPU where `taskset` exists), and the scan has no `| grep -q`.

### The README names `git` for the `npx` install line (#440)

- The README said `node` ≥ 18 was the only prerequisite for `npx -y github:VocanicZ/Harness`, and that
  the installer offers `git`. But npm fetches a `github:` package by running `git`, so on a host
  without it (a fresh Ubuntu/Debian with node from apt) `npx` failed with an npm error
  (`spawn git`, "An unknown git error occurred") before `install.sh` ran, and nothing offered `git`.
- The README's prerequisite table now lists `git` for the `npx` line, the agent note sends a host
  without `git` to the `curl` line (which offers to install it), and `/harness <idea>` step 1 says the
  same.
- `test/test_install_npx.sh`: on a PATH with `node` and `npm` but no `git` (throwaway HOME and npm
  cache, offline), npm cannot fetch `github:VocanicZ/Harness` and fails spawning `git`; the README
  names `git` for the `npx` line, and the agent note and skill send a git-less host to `curl`.

### The `/harness` skills reach every installed CLI, Hermes included, as links (#439)

- A host with Hermes got no `/harness*` skills in Hermes: `install.sh` copied them into
  `~/.claude/skills` and the agy, codex and copilot dirs only, and the operator's Hermes reads
  `~/.hermes/skills`. Every adapter now names the dir its CLI reads user skills from
  (`cli_user_skills_dir`; hermes: `~/.hermes/skills`, openclaw: `~/.agents/skills`), and every
  supported CLI installed on the host (binary on PATH, or its config dir present) gets every engine
  skill there.
- Each skill is a symlink to the one copy in the engine, named through `~/.harness/engine/skill/`, so
  an update refreshes every CLI at once; `harness/` is a dir holding a `SKILL.md` link. Hermes follows
  them (`test/fixtures/cli/hermes/skills-symlink.txt`: listed and loaded by the real Hermes).
- Every `harness update` — no flags, already current included, run from the new release after a
  flip — and `harness setup` / `harness start` re-link: a missing, dangling or old-release link, or an
  old Harness copy, is relinked. A same-named skill of the operator's own is kept, and the update
  names it. `harness uninstall` removes only Harness's links, dangling ones too (it now reads the CLIs'
  dirs before it removes the engine).
- `test/test_operator_skills.sh`: a fake HOME with every CLI on PATH and an old install (copies in
  `~/.claude/skills` only) gets links in every CLI's dir from a plain `harness update`; an operator's
  own `~/.hermes/skills/harness` is untouched; a removed link comes back; setup/start heal; uninstall.
  Matrix row `operator-skills`. `test/test_hermetic.sh`: no update test links into the inherited HOME.

### The update tests no longer touch the host's real engine (#434)

- `test/test_update.sh` and `test/test_web_install.sh` set no `HARNESS_HOME`, so `update.sh` read the
  host's real `~/.harness/engine`. Every host installed since releases (#279) has a release symlink
  there, so both tests failed on such a host and queried the real GitHub releases API. With a newer
  release published, `test_web_install.sh` would have installed it over the live engine. Both tests
  now set a throwaway `HOME` and `HARNESS_HOME` and a local releases URL, and pass with or without a
  `~/.harness`.
- `test/test_hermetic.sh` finds every suite test that runs `update.sh` or `harness update`. It runs
  each one against a decoy home whose engine is a release symlink, with a curl tripwire on PATH.
  Each test must pass, leave the decoy's `.harness` unchanged, and never reach github.com.

### The `/harness-*` skills run `harness` off PATH (#433)

- `/harness-prd` (where `/harness <idea>` goes on a live fleet) and the other per-command skills
  (`/harness-init`, `-issue`, `-one`, `-pause`, `-plan`, `-resume`, `-start`, `-status`, `-stop`,
  `-uninstall`) still ran `.harness/bin/harness`, which nothing creates any more, so the agent ran a
  missing path and the idea never reached the fleet. They now run `harness <cmd>`, the command
  `install.sh` puts on PATH, with the same arguments (#343 had fixed only `/harness`).

### `/harness <idea>` files its PRD on a fresh repo (#432)

- A non-interactive `harness init` (the agent's shell, which has no terminal) wrote the config and
  seeded no labels, so `/harness <idea>` step 3's `gh issue create --label prd` failed
  `could not add label: 'prd' not found`. Non-interactive init now seeds the harness labels on a
  single-topology repo when `gh` is signed in (labels only; `harness setup` still disables the
  repo's Actions); signed out, it prints a NOTE naming `harness setup`. `HARNESS_INIT_SEED=0` skips it.
- `/harness` step 2: the `prd` label must exist before the PRD is filed — init seeds it, else
  `harness setup` runs before step 3.

### Claude Code installed by the prerequisite offer is found in `~/.local/bin` (#431)

- Accepting install.sh's "install Claude Code?" offer on a fresh Linux host still ended in
  `MISSING: an agent CLI`: Claude Code's native installer puts `claude` in `~/.local/bin`, which a
  fresh session's PATH often lacks. install.sh now puts `~/.local/bin` on PATH for the rest of the
  install when it exists (before it offers or checks an agent CLI), and `_cli_bin_ensure` does the
  same after a vendor installer lands the binary there, so the check passes and a re-run does not
  offer the install again.
- When the agent CLI or the `harness` link sits only in a directory the user's own PATH lacks, the
  installer prints the exact `export PATH=...` line and says to re-open the shell; it does not fail.
- `/harness` step 1: after installing, a `harness` still off PATH is run as `~/.local/bin/harness`
  and the user is told the PATH line.

### Ending a headless lane ends its detached background jobs (#427)

- #418's guarantee did not hold on `HARNESS_SESSION_BACKEND=headless`: a turn that ended normally
  left its background jobs (`sleep 777 &`, a `setsid`'d server) running, re-parented, and neither
  `sess_kill` on the idle lane nor the stats sweep of a lane that exited on its own reached them.
  The lane now records the `HARNESS_SESSION` uuid it started with, and both end every process whose
  environment carries it exactly (`proc_sweep_session`: SIGTERM, then SIGKILL after
  `HARNESS_SWEEP_GRACE`; never the caller, its ancestors or a tracked worker; by pid only).
- A lane relaunched on its claude session keeps its uuid: nothing is swept while a live lane carries it.
- On Windows a process still up after the grace is also `taskkill /F`'d by its winpid.

### Dispatch never re-claims an issue its live lane still owns (#416)

- Dispatch decided an issue was claimable from its labels alone, so a live lane that dropped
  `agent-working` (it checkpointed, or parked itself `agent-paused`) had its issue re-claimed every
  pool pass: `agent-working` flapped, `worktree add failed #<n>` repeated, the stuck issue took the
  free slot ahead of real work (resumable-first, #210), and the re-stamp reset a self-parked lane's
  grace timer, so #417's checkpoint never fired. The pool now passes the issues a lane still owns —
  an impl/bug/triage worktree, a live impl or bug session, a fresh `harness one` lease — to
  `issuelib.py dispatch --busy-issues`, which drops them before slots are counted. A dead lane's
  issue (no session, no worktree) still resumes as before.
- `prepare_impl` stamps `agent-working` only after `git worktree add` succeeds (as `spawn_bug` has
  since #34), so a failed add no longer leaves the label behind.

### `harness stats` no longer double-counts a headless lane's tokens (#426)

- A headless lane relaunched on its claude session (after a checkpoint, a crash or a usage park)
  appends to the same transcript; its `session_end` re-counted the earlier run. It now reports only
  what that run added, flagged `resumed: true`, and `harness stats` adds it to the session's earlier
  runs — the two `session_end`s sum to the session's real usage. Earlier logs read as before.
- A lane with no transcript summed every turn's stream-json `modelUsage`, which on a `--resume`d
  turn is the session's running total. Each turn now counts its own usage
  (`model_usage_since_last_result`, or `modelUsage` less the previous turn's).
- tmux lanes are unchanged.

### `harness stats --by-role` (#378)

- Tokens (input, output, cache) and list-price $ per role — Manager, Implementer, and `other` for a
  session whose kind says neither — so the per-role model saving is measurable before and after.
  Works on history from before roles (by session kind, or the worktree name), and takes the usual
  filters (`--since`, `--fleet`, `-R`, `--model`, `--prd`, `--issue`) and `--json`.

### A lane that parks itself `agent-paused` no longer holds its slot (#417)

- On an autonomous fleet, an impl lane that swaps its issue to `agent-paused` without a
  `HARNESS CHECKPOINT` (to wait for a human decision) used to idle at its prompt forever: the reap,
  the stall watchdog and the supervisor's nudges all let it be. The pool's poll now sees it
  (`issuelib.py check ISSUE:<n>` reads `PAUSED`: open, `agent-paused`, no `agent-working`), sends it
  one nudge to decide and continue, and, if it is still parked after `HARNESS_SELFPARK_GRACE_MIN`
  minutes (new, default 30), checkpoints it mechanically (WIP pushed, `harness-handoff` comment) and
  ends it; the issue then resumes from `resume.md`. Work that cannot be pushed is never killed.
- Every checkpoint the engine sends (`pause --force`, the usage checkpoint, `harness one`) now records
  `run/<session>.checkpoint`, so a requested pause is never mistaken for a self-park.
- `impl.md`, `resume.md` and `bug-fix.md` reserve `agent-paused` for a received `HARNESS CHECKPOINT`;
  `resume.md` tells an autonomous lane to settle a handoff's open decision itself and document it.

### A tmux lane's background jobs end with it (#418)

- Killing a tmux lane (`sess_kill`: reapers, `harness supervise`, adapters) now also ends what it left
  running. `tmux kill-session` only reached the pane's own process group, so a detached background job
  the agent started (a test server, `tail -F`, a watcher) outlived the lane forever, holding ports and
  RAM. The kill now reads the session's `HARNESS_SESSION` and its panes' process trees first, then
  SIGTERMs every process whose environment carries that uuid exactly, plus the pane tree, and
  SIGKILLs what is still up after `HARNESS_SWEEP_GRACE` seconds (default 3).
- A lane that exits on its own (Ralph promise, inject loop end) is swept the same way by
  `stats_sweep_ended` when it claims the session's stats context (new seam function `sess_sweep`;
  a no-op on the headless backend, whose runner already ends a turn's tree).
- By pid only, never by pattern: a near-miss uuid, an argv naming the uuid, the caller and its
  ancestors, the tmux server and the fleet's tracked workers are never touched.

### Verify what ran: `model_mismatch` (#376)

- At `session_end`, the model with the most output tokens in the session is compared with the model
  its launch logged, by family (`sonnet` = `claude-sonnet-5-5`). A different family emits a
  `model_mismatch` event (intended, actual, session, issue), flagged in `harness status`,
  `harness stats` and the web dashboard. Side calls on another model never trip it; a lane on the
  CLI's default model is not checked.

### Caveman in every lane (#377)

- Every session prompt — plan, prd, decompose, review, bug-triage, bug-fix, impl, resume, inject —
  invokes the `caveman` skill at session start through one shared partial, `prompts/_caveman.md`.
  Before, only impl and bug-fix did.
- Scoped: caveman for the session's own output and agent-to-agent comments (handoffs, review
  findings, checkpoint notes); human-facing artifacts (PRD and issue bodies, PR descriptions, docs,
  README, commit messages) stay plain prose; exact strings (code, commands, errors, labels, issue
  refs) are never compressed.

See [docs/reference.md § Lane output style](docs/reference.md#lane-output-style-caveman).

### Workers and headless lanes exit when their home is deleted (#419)

- `pool-worker.sh` and `priority-worker.sh` exit 0 (logging the missing path) once the `STATE_DIR` or
  `HARNESS_HOME` they serve is deleted or replaced. The check runs first in every poll, before any
  `mkdir -p` could re-create the root, so a leaked worker no longer calls `gh` from a dead home or
  re-creates `$HARNESS_HOME/poller` on every tick.
- `claude_headless.py run` stops itself when its lane dir is deleted (whose `stop` file can then
  never be written): idle, it exits 0; mid-turn, it kills the claude child's process tree first. It
  writes nothing more and does not re-create the lane.
- Tests: `tmp_cleanup` (`test/helpers.sh`) now stops this user's processes whose cwd, or
  `STATE_DIR` / `HARNESS_HOME` / `HARNESS_LANE_DIR`, is inside a tracked dir before removing it — by
  path, never by command-line pattern. A no-op without `/proc`.

### Roles: model and effort per lane (#375)

- Every lane is a **Manager** (orchestration `-p*`: PLAN, PRD, DECOMPOSE, REVIEW/gauntlet; bug triage;
  the injector) or an **Implementer** (issue lanes `-i*`, incl. `resume.md`; bug fixes), and launches
  with its role's model and effort: `HARNESS_MODEL_MANAGER`, `HARNESS_EFFORT_MANAGER`,
  `HARNESS_MODEL_IMPLEMENTER`, `HARNESS_EFFORT_IMPLEMENTER`.
- Defaults on `claude`: `opus`/`high` (Manager), `sonnet`/`high` (Implementer). Every other CLI: empty =
  the CLI's own default unless configured.
- Precedence: a worktree hook's `.harness-lane` > the role keys > a `--model`/`--effort` in
  `HARNESS_*_FLAGS`. `harness init` asks for and shows both roles.
- **Behaviour change:** a fleet pinning `--model opus` in `HARNESS_CLAUDE_FLAGS` (harness-dev, ORGE,
  bangwa) gets Sonnet implementers after this. Set `HARNESS_MODEL_IMPLEMENTER=opus` in
  `.harness/config` to keep the old behaviour.

See [docs/reference.md § Roles](docs/reference.md#roles-model-and-effort-per-lane).
