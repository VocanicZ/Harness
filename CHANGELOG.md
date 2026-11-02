# Changelog

Notable changes to Harness. Releases and their full notes: [GitHub Releases](https://github.com/VocanicZ/Harness/releases).

## Unreleased

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
