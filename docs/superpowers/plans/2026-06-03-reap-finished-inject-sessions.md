# Reap Finished Inject Sessions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill a `hz-inject-<unit>` tmux session once its Ralph loop has ended, so finished injectors stop lingering at the idle `❯` prompt.

**Architecture:** inject sessions are excluded from `team_sessions` by design, so no goal-check reaper iterates them. The ralph-loop stop-hook removes `.claude/ralph-loop.local.md` the instant the loop ends (promise / max-iter / error), leaving the session alive but the state file gone. A new per-poll `reap_finished_inject` keys off "state file absent" to kill the parked session. `launch_claude` records each session's worktree in a `.wd` sidecar so the reaper can locate the state file.

**Tech Stack:** bash (`scripts/lib.sh`, `scripts/drive.sh`), tmux, bash test rig (`test/helpers.sh`, run via `test/run.sh`).

**Spec:** `docs/superpowers/specs/2026-06-03-reap-finished-inject-sessions-design.md`

---

## File Structure

- `scripts/lib.sh` — add `reap_finished_inject`; have `launch_claude` write a `.wd` sidecar; extend `gc_orphan_goals` to clean `.wd`.
- `scripts/drive.sh:245` — call `reap_finished_inject "$UNIT"` in the per-poll hook.
- `test/test_reap_inject.sh` — new focused test file (mirrors `test_inject.sh` conventions: `make_env`, stub `tmux`/`session_live`, `finish`).

All work on branch `fix/reap-finished-inject-sessions` (off `origin/main` @ #116) in worktree `/home/claude/wt-reap-inject`.

---

### Task 1: `reap_finished_inject` (the reaper)

**Files:**
- Test: `test/test_reap_inject.sh` (create)
- Modify: `scripts/lib.sh` (add function near `gc_orphan_goals`, ~line 491)

- [ ] **Step 1: Write the failing test**

Create `test/test_reap_inject.sh`:

```bash
#!/usr/bin/env bash
# test_reap_inject.sh — reap_finished_inject + launch_claude .wd sidecar + gc_orphan_goals .wd cleanup.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_SESS_PREFIX=hz
log(){ :; }                                   # silence engine logging in tests
KILLED="$RUN_DIR/killed.log"; : > "$KILLED"
# stub tmux so `kill-session -t <sess>` is recorded ($1=kill-session $2=-t $3=<sess>)
tmux(){ [[ "$1" == kill-session ]] && echo "$3" >> "$KILLED"; return 0; }

SESS=hz-inject-main
WD="$(mktemp -d)"; mkdir -p "$WD/.claude"

# ── live inject + ABSENT state file → reaped ──────────────────────────────────
echo INJECT > "$RUN_DIR/$SESS.goal"; echo "$WD" > "$RUN_DIR/$SESS.wd"
rm -f "$WD/.claude/ralph-loop.local.md"
session_live(){ [[ "$1" == hz-inject-main ]]; }
: > "$KILLED"
reap_finished_inject main
assert_ok "reaped: kill-session hz-inject-main" bash -c "grep -qx hz-inject-main '$KILLED'"
assert_no "reaped: .goal removed" test -f "$RUN_DIR/$SESS.goal"
assert_no "reaped: .wd removed"   test -f "$RUN_DIR/$SESS.wd"

# ── live inject + PRESENT state file → NOT reaped ─────────────────────────────
echo INJECT > "$RUN_DIR/$SESS.goal"; echo "$WD" > "$RUN_DIR/$SESS.wd"
: > "$WD/.claude/ralph-loop.local.md"
: > "$KILLED"
reap_finished_inject main
assert_no "loop active → not reaped" bash -c "grep -qx hz-inject-main '$KILLED'"
assert_ok "loop active → .goal kept" test -f "$RUN_DIR/$SESS.goal"

# ── .wd missing (launching / legacy) → NOT reaped ─────────────────────────────
rm -f "$RUN_DIR/$SESS.wd"; echo INJECT > "$RUN_DIR/$SESS.goal"
: > "$KILLED"
reap_finished_inject main
assert_no ".wd missing → not reaped" bash -c "grep -qx hz-inject-main '$KILLED'"

# ── session not live → no-op ──────────────────────────────────────────────────
echo "$WD" > "$RUN_DIR/$SESS.wd"; rm -f "$WD/.claude/ralph-loop.local.md"
session_live(){ return 1; }
: > "$KILLED"
reap_finished_inject main
assert_no "session dead → no-op" bash -c "grep -qx hz-inject-main '$KILLED'"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test_reap_inject.sh`
Expected: FAIL — `reap_finished_inject: command not found` (function not defined yet), non-zero exit.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib.sh`, immediately AFTER the `gc_orphan_goals(){ ... }` function (the line with the closing `}` near line 491), add:

```bash
# reap_finished_inject <unit> — kill the unit's inject session once its Ralph loop has ended.
# inject sessions are excluded from team_sessions by design (no CAP slot, inject.sh:5), so NO
# goal-check reaper (reap_done_sessions / priority-worker) ever iterates them — a finished injector
# parks at the idle ❯ prompt forever. Authoritative done-signal: the ralph-loop stop-hook removes
# .claude/ralph-loop.local.md the instant the loop ends (promise, max-iter, OR error), leaving the
# session alive but the state file gone. So: live inject session + absent state file ⇒ finished ⇒
# reap. A still-looping session (file present) or a launching/legacy one (no .wd recorded) is left
# untouched. Scoped to THIS fleet+unit's sess_inject; can never touch a driven/team session.
reap_finished_inject(){ local unit="$1" sess wd
  sess="$(sess_inject "$unit")"
  session_live "$sess" || return 0
  wd="$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" || return 0
  [[ -n "$wd" ]] || return 0
  [[ -f "$wd/.claude/ralph-loop.local.md" ]] && return 0   # loop still active → leave it
  log "reaped finished inject session $sess (ralph loop ended)"
  tmux kill-session -t "$sess" 2>/dev/null || true
  rm -f "$RUN_DIR/$sess.goal" "$RUN_DIR/$sess.wd"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test_reap_inject.sh`
Expected: PASS — `7/7 passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add test/test_reap_inject.sh scripts/lib.sh
git commit -m "feat(reap): reap_finished_inject kills an inject session once its ralph loop ends

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `launch_claude` writes the `.wd` sidecar

**Files:**
- Test: `test/test_reap_inject.sh` (append a case)
- Modify: `scripts/lib.sh:649` (`launch_claude`, after the `.goal` write)

- [ ] **Step 1: Write the failing test**

In `test/test_reap_inject.sh`, BEFORE the final `finish` line, insert:

```bash
# ── launch_claude records the worktree in a .wd sidecar ───────────────────────
PROMISE=X; MAXITER=3; GOAL=INJECT
CLAUDE_BIN=true; CLAUDE_FLAGS=""
sleep(){ :; }; ensure_trusted(){ :; }; ensure_bypass(){ :; }   # stub the launch side-effects
tmux(){ [[ "$1" == kill-session ]] && echo "$3" >> "$KILLED"; return 0; }
session_live(){ return 1; }                                    # not already live → proceed
WD2="$(mktemp -d)"; echo task > "$WD2/.harness-task.md"
launch_claude hz-inject-main "$WD2" >/dev/null 2>&1
assert_ok "launch_claude writes .wd sidecar" bash -c "grep -qx '$WD2' '$RUN_DIR/hz-inject-main.wd'"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test_reap_inject.sh`
Expected: FAIL on "launch_claude writes .wd sidecar" — the `.wd` file is not written yet.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib.sh`, find line 649:

```bash
  echo "${GOAL:-?}" > "$RUN_DIR/$sess.goal"
```

Add a line immediately after it:

```bash
  echo "${GOAL:-?}" > "$RUN_DIR/$sess.goal"
  echo "$wd" > "$RUN_DIR/$sess.wd"   # record worktree so reap_finished_inject can find the ralph state file
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test_reap_inject.sh`
Expected: PASS — `8/8 passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add test/test_reap_inject.sh scripts/lib.sh
git commit -m "feat(reap): launch_claude records each session's worktree in a .wd sidecar

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `gc_orphan_goals` cleans the `.wd` sidecar

**Files:**
- Test: `test/test_reap_inject.sh` (append a case)
- Modify: `scripts/lib.sh:483-491` (`gc_orphan_goals`)

- [ ] **Step 1: Write the failing test**

In `test/test_reap_inject.sh`, BEFORE the final `finish` line, insert:

```bash
# ── gc_orphan_goals also removes a dead session's .wd sidecar ─────────────────
echo INJECT > "$RUN_DIR/hz-dead-i1.goal"; echo /tmp/whatever > "$RUN_DIR/hz-dead-i1.wd"
session_live(){ return 1; }   # every session dead
gc_orphan_goals
assert_no "gc removed dead .goal" test -f "$RUN_DIR/hz-dead-i1.goal"
assert_no "gc removed dead .wd"   test -f "$RUN_DIR/hz-dead-i1.wd"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test_reap_inject.sh`
Expected: FAIL on "gc removed dead .wd" — `gc_orphan_goals` only removes the `.goal`, the `.wd` lingers.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib.sh`, change the loop body of `gc_orphan_goals`. Find:

```bash
    sess="$(basename "$f" .goal)"
    session_live "$sess" || rm -f "$f"
```

Replace with:

```bash
    sess="$(basename "$f" .goal)"
    session_live "$sess" || rm -f "$f" "$RUN_DIR/$sess.wd"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test_reap_inject.sh`
Expected: PASS — `10/10 passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add test/test_reap_inject.sh scripts/lib.sh
git commit -m "feat(reap): gc_orphan_goals sweeps the .wd sidecar of a dead session too

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Wire `reap_finished_inject` into the drive poll

**Files:**
- Modify: `scripts/drive.sh:245`

- [ ] **Step 1: Make the edit**

In `scripts/drive.sh`, find line 245:

```bash
    reap_done_sessions; reap_team; watchdog_team   # #115: recover a session wedged at idle ❯ by a transient API error
```

Replace with:

```bash
    reap_done_sessions; reap_team; watchdog_team; reap_finished_inject "$UNIT"   # #115 watchdog + reap a finished injector parked at idle ❯
```

- [ ] **Step 2: Verify the drive smoke test still passes**

Run: `bash test/test_drive.sh`
Expected: PASS (no regression — the new call is a no-op when no inject session is live).

- [ ] **Step 3: Commit**

```bash
git add scripts/drive.sh
git commit -m "feat(reap): call reap_finished_inject every drive poll

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Full suite green + push + PR

- [ ] **Step 1: Run the whole suite**

Run: `bash test/run.sh`
Expected: every `test_*.sh` / `test_*.py` passes, exit 0. If anything fails, fix before proceeding (do not push red).

- [ ] **Step 2: Push the branch**

```bash
git push -u origin fix/reap-finished-inject-sessions
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create -R VocanicZ/Harness --base main --head fix/reap-finished-inject-sessions \
  --title "fix: reap a finished inject session (ralph loop ended) so it stops lingering at idle ❯" \
  --body "$(cat <<'BODY'
## Problem
A finished `hz-inject-<unit>` tmux session is never killed — it parks at the idle `❯` prompt forever. inject sessions are excluded from `team_sessions` by design (no CAP slot), so no goal-check reaper iterates them.

## Fix
- `reap_finished_inject <unit>` (lib.sh): live inject session + absent `.claude/ralph-loop.local.md` ⇒ ralph loop ended ⇒ kill + GC goal/wd. The stop-hook removes that file on promise/maxiter/error, so its absence is the authoritative done-signal.
- `launch_claude` records each session's worktree in a `.wd` sidecar so the reaper can locate the state file.
- `gc_orphan_goals` sweeps the `.wd` sidecar of a dead session too.
- Wired into the per-poll hook in `drive_unit` beside the existing reapers.

Driven/bug sessions keep their existing GitHub goal-`check` reapers — untouched. Scoped to this fleet+unit's `sess_inject`; no cross-fleet kill.

Spec + plan: `docs/superpowers/specs/2026-06-03-reap-finished-inject-sessions-design.md`, `docs/superpowers/plans/2026-06-03-reap-finished-inject-sessions.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

- [ ] **Step 4: Report the PR URL to the user.** Merge (`--squash` when CLEAN) and `harness update` are user-gated — do NOT auto-merge (repo forbids `--auto`).

---

## Self-Review

- **Spec coverage:** reaper (Task 1) ✓; `.wd` sidecar (Task 2) ✓; `gc_orphan_goals` `.wd` cleanup (Task 3) ✓; per-poll wiring (Task 4) ✓; tests-first + full suite green (Tasks 1-3, 5) ✓; rollout via PR + `harness update` (Task 5) ✓. Out-of-scope items (retired-pool inject, #115 watchdog) intentionally untouched.
- **Placeholder scan:** none — every code/command step shows actual content.
- **Type/name consistency:** `reap_finished_inject` / `sess_inject` / `session_live` / `gc_orphan_goals` / `$RUN_DIR/<sess>.wd` used identically across plan, tests, and implementation. Test pass counts (7 → 8 → 10) account for cumulative asserts appended in Tasks 2 and 3.
