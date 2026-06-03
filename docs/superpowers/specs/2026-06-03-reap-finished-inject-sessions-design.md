# Reap finished inject sessions

**Status:** approved (design) — 2026-06-03
**Branch:** `fix/reap-finished-inject-sessions` (off `origin/main` @ `c8d3eb8` / #116)

## Problem

A finished `hz-inject-<unit>` tmux session is never killed. It lingers at the
interactive `❯` idle prompt indefinitely, holding a worktree and showing up in
`tmux ls` long after its work is done. Observed in production: `hz-inject-main`
sat alive ~1 day after emitting `<promise>INJECT DONE</promise>`.

This is **not** a regression of the PR #87 reap fix. PR #87's `gc_orphan_goals`
sweeps orphaned `.goal` *files* belonging to **dead** sessions — and it works
(zero orphan goals on disk). The #115 watchdog reaps a session parked at idle
`❯` only when a **transient-API-error** marker is present. Neither path touches
a cleanly-finished inject session.

## Root cause

The engine has three reapers, each keyed to a session class:

| Session class            | Reaper                                  | Signal                          |
|--------------------------|-----------------------------------------|---------------------------------|
| driven team / orch       | `reap_done_sessions` (drive.sh:51)      | GitHub goal `check` == DONE     |
| bug lane                 | `priority-worker.sh:43`                 | bug goal done                   |
| **inject (`hz-inject-*`)** | **none**                              | **—**                           |

`inject.sh` sessions are deliberately named so they do **not** appear in
`team_sessions` (so they consume no CAP/orch slot — see inject.sh:5). The
consequence is that **no reaper ever iterates them**. When an inject session
finishes, nothing kills it.

### Why a finished session parks instead of exiting

The ralph-loop **stop-hook deletes the state file the instant the loop ends**,
for *any* reason — promise detected, `max_iterations` reached, or
error/corruption (`ralph-loop/.../hooks/stop-hook.sh` lines 45/56/63/75/86/102/
124/139/162). It then `exit 0`s, which *allows* the session to stop: `claude`
ends its turn loop and **parks at the idle `❯` prompt**. The process and tmux
session stay alive; only the state file is gone.

## Authoritative completion signal

**A Ralph session is finished ⟺ its `.claude/ralph-loop.local.md` no longer
exists.** While the loop is active the file is present; the stop-hook removes it
on completion/exhaustion/error. This is scrape-free and already read elsewhere
(`status.sh:iter_of`).

Driven/bug sessions keep their existing **GitHub goal-`check`** reapers
(unchanged). Inject has no GitHub goal — its job is "run the loop once to
completion" — so its authoritative done-signal *is* "the Ralph loop terminated"
= **state file absent**. Each session class reaps on its own provable
completion; never on a "looks idle" guess.

## Design

Three small pieces.

### 1. `launch_claude` records the worktree (lib.sh)

Alongside the existing `echo "${GOAL:-?}" > "$RUN_DIR/$sess.goal"`, also write
`$RUN_DIR/$sess.wd` containing the worktree path. A generic reaper needs to
locate any session's state file from its session name; the `.wd` sidecar is that
map. (Currently only `drive.sh` knows a unit's `CHECKOUT`; inject's worktree is
not otherwise recoverable from the session name in a unit-agnostic sweep.)

### 2. `reap_finished_inject` (lib.sh)

```
reap_finished_inject <unit>:
  for each live session matching sess_inject(unit):      # this fleet, this unit only
    wd = read $RUN_DIR/<sess>.wd                          # skip if missing (legacy/launching)
    if NOT exists "$wd/.claude/ralph-loop.local.md":      # loop ended → finished
      tmux kill-session -t <sess>
      rm -f $RUN_DIR/<sess>.goal $RUN_DIR/<sess>.wd
      log "reaped finished inject session <sess> (ralph loop ended)"
```

A session still mid-loop (state file present) or mid-launch is left untouched.

### 3. Wire into the per-poll hook (drive.sh)

Add `reap_finished_inject "$UNIT"` to the existing per-poll line in `drive_unit`
beside `reap_done_sessions; reap_team; watchdog_team` (drive.sh:245). Per-unit
drive loops each reap their own inject session.

### 4. `gc_orphan_goals` also cleans `.wd` (lib.sh)

Extend the existing sweep so a dead session's `.wd` sidecar is removed too,
mirroring the `.goal` cleanup — no new orphan class introduced.

## Safety guarantees

- **No TOCTOU.** `write_state` writes the state file *before* `tmux
  new-session`, so a launching session always has its file present → never
  falsely reaped in the startup window. The `.wd` sidecar is written right after
  the `.goal` (same session-is-live point), so a sweep in the launch gap finds
  the session live and the file present.
- **No cross-fleet kill.** Only sessions matching `sess_inject "$UNIT"` for this
  fleet's `HARNESS_SESS_PREFIX` are ever touched. `hz` vs `hzli` isolation holds
  (the trailing-dash rule in `fleet_session_re` / `prefixes_collide`).
- **Driven sessions untouched** by the new path — they can only be reaped by the
  existing GitHub goal-`check` reaper, never before their goal is satisfied.
- **Next-poll latency.** A finished inject session is reaped on the next drive
  poll after its loop ends — not a beat sooner (it won't be killed while still
  looping), not indefinitely later.

## Out of scope (flagged, not silently dropped)

- **Inject into a retired pool.** If the pool has exited (all units complete) and
  an inject is launched afterward, no drive loop is running to reap it. `inject.sh`
  already warns the work will sit unclaimed and points at `start --recover`; the
  reaper covers the normal live-pool case. Not addressed here.
- The #115 transient-error watchdog stays as-is (orthogonal: it handles
  busy/error-wedged **driven** sessions mid-task).

## Testing (tests-first)

Extend `test/test_inject.sh` (or a focused `test/test_reap_inject.sh`), using the
existing `make_env` + `tmux`/`session_live` stub pattern:

- live inject session + **absent** state file → reaped (`tmux kill-session`
  invoked; `.goal` and `.wd` removed).
- live inject session + **present** state file → **not** reaped.
- session whose `.wd` is missing (legacy/launching) → **not** reaped.
- a non-inject team session with an absent state file → **not** touched by
  `reap_finished_inject` (only `reap_done_sessions` governs it).
- `launch_claude` writes the `.wd` sidecar; `gc_orphan_goals` removes a dead
  session's `.wd`.

Full suite (`test/run.sh`) must stay green.

## Rollout

Merge via PR (`--squash` when CLEAN — repo forbids `--auto`), then `harness
update` on the host to ff-pull into the shared `~/.harness/engine`. Both `hz`
and `hzli` fleets pick up the fix on their next poll.
