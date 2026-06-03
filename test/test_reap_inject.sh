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

# ── launch_claude records the worktree in a .wd sidecar ───────────────────────
PROMISE=X; MAXITER=3; GOAL=INJECT
CLAUDE_BIN=true; CLAUDE_FLAGS=""
sleep(){ :; }; ensure_trusted(){ :; }; ensure_bypass(){ :; }   # stub the launch side-effects
tmux(){ [[ "$1" == kill-session ]] && echo "$3" >> "$KILLED"; return 0; }
session_live(){ return 1; }                                    # not already live → proceed
WD2="$(mktemp -d)"; echo task > "$WD2/.harness-task.md"
launch_claude hz-inject-main "$WD2" >/dev/null 2>&1
assert_ok "launch_claude writes .wd sidecar" bash -c "grep -qx '$WD2' '$RUN_DIR/hz-inject-main.wd'"

finish
