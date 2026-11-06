#!/usr/bin/env bash
# test_lane_cleanup.sh — #610: the fleet cleans up what a lane leaves behind.
#   1. a lane session gets its own TMPDIR (lane_tmp_env), and reaping the lane removes it — so the
#      mktemp dirs a test in the lane never deleted do not pile up in /tmp (a tmpfs: RAM).
#   2. the goal check that ends a session removes its .wd with its .goal, and gc_orphan_goals sweeps a
#      .wd / .loop whose .goal is already gone — but never a live session's.
#   3. close_prd removes the PRD's gauntlet dir; the recovery sweep removes those of closed PRDs only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"; make_env
log(){ :; }
T="$(mktemp -d)"; tmp_track "$T"

echo "-- a lane launches with its own TMPDIR, and the reap removes everything a test left in it"
export HARNESS_TMP_ROOT="$T/tmproot"; mkdir -p "$HARNESS_TMP_ROOT"
co="$T/co"; git init -q "$co"; git -C "$co" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
wd="$T/worktrees/u-i610"; git -C "$co" worktree add -q "$wd" 2>/dev/null
echo task > "$wd/.harness-task.md"
SESS=hz-u-i610; HARNESS_SESS_PREFIX=hz; PROMISE=X; MAXITER=1; GOAL="ISSUE:610"; CLAUDE_BIN=true; CLAUDE_FLAGS=""
sleep(){ :; }; ensure_trusted(){ :; }; ensure_bypass(){ :; }; ensure_usage_statusline(){ :; }
NEWSESS="$RUN_DIR/new-session.args"; : > "$NEWSESS"
tmux(){ case "$1" in has-session) return 1;; new-session) printf '%s\n' "$@" >> "$NEWSESS";; esac; return 0; }
launch_claude "$SESS" "$wd" >/dev/null 2>&1
want="$(lane_tmpdir "$wd")"
assert_eq "$(dirname "$want")" "$HARNESS_TMP_ROOT" "the lane's TMPDIR sits directly under the tmp root"
assert_ok "the session is started with TMPDIR=<lane dir>" grep -qxF "TMPDIR=$want" "$NEWSESS"
assert_ok "the lane dir exists once the lane is up" test -d "$want"
assert_no "a different worktree gets a different lane dir" test "$(lane_tmpdir "$wd")" = "$(lane_tmpdir "$T/worktrees/u-i611")"
# What a test in the lane leaves behind: mktemp dirs, a nested tree, a tmux socket dir.
mkdir -p "$want/tmp.AbC123/deep/er" "$want/tmpXyZ" "$want/models.1"
mkdir -p "$HARNESS_TMP_ROOT/keep-me"
remove_worktree "$co" "$wd"
assert_no "the lane dir is gone with the worktree" test -e "$want"
assert_eq "$(ls -A "$HARNESS_TMP_ROOT")" "keep-me" "nothing of the lane's run remains in the tmp root, and another entry is untouched"
unset HARNESS_TMP_ROOT

echo "-- the goal check removes .goal and .wd together"
ISSUELIB="$T/check.py"; printf 'print("DONE")\n' > "$ISSUELIB"
cli_kill(){ echo "kill $1 wd=$2" >> "$RUN_DIR/kills"; return 0; }
REPO=acme/widget
echo "ISSUE:7" > "$RUN_DIR/hz-u-i7.goal"; echo "$T/wd7" > "$RUN_DIR/hz-u-i7.wd"
check_session_goal hz-u-i7
assert_ok "the session was killed with its recorded worktree" grep -qx "kill hz-u-i7 wd=$T/wd7" "$RUN_DIR/kills"
assert_no "the .goal is gone" test -e "$RUN_DIR/hz-u-i7.goal"
assert_no "the .wd is gone"   test -e "$RUN_DIR/hz-u-i7.wd"

echo "-- gc_orphan_goals sweeps a .wd / .loop with no .goal, never a live session's"
LIVE="$RUN_DIR/live"; echo hz-u-i8 > "$LIVE"; session_live(){ grep -qxF "$1" "$LIVE"; }
for s in hz-u-i8 hz-u-i9; do echo /w > "$RUN_DIR/$s.wd"; : > "$RUN_DIR/$s.loop"; : > "$RUN_DIR/$s.loop.lock"; done
gc_orphan_goals
for e in wd loop loop.lock; do
  assert_no "dead session's .$e (no .goal) is swept" test -e "$RUN_DIR/hz-u-i9.$e"
  assert_ok "live session's .$e (no .goal) is kept"  test -e "$RUN_DIR/hz-u-i8.$e"
done
echo ISSUE:8 > "$RUN_DIR/hz-u-i8.goal"; gc_orphan_goals
assert_ok "a live session's .goal and .wd both stay" test -e "$RUN_DIR/hz-u-i8.goal" -a -e "$RUN_DIR/hz-u-i8.wd"

echo "-- close_prd removes the PRD's gauntlet dir; the recovery sweep removes closed PRDs' only"
STATE_DIR="$T/state"; UNIT="$(all_units)"; SLUG=acme/widget
harness_event(){ :; }; release_on_prd_close(){ :; }
mk(){ mkdir -p "$STATE_DIR/gauntlet/$UNIT/p$1/r1"; echo ev > "$STATE_DIR/gauntlet/$UNIT/p$1/r1/A"; }
G(){ echo "$STATE_DIR/gauntlet/$UNIT/p$1"; }
mk 192; mk 193; mk 194
gh(){ return 1; }; close_prd 192
assert_ok "a close that failed keeps the dir (it retries next poll)" test -d "$(G 192)"
gh(){ return 0; }; close_prd 192
assert_no "after CLOSE_PRD the gauntlet dir is gone" test -e "$(G 192)"
assert_ok "another PRD's dir is untouched"           test -d "$(G 193)"
gh(){ case "$3" in 193) echo CLOSED;; 194) echo OPEN;; 195) return 1;; esac; }
mk 195; mkdir -p "$STATE_DIR/gauntlet/$UNIT/notaprd"
sweep_closed_gauntlet >/dev/null
assert_no "sweep removes the closed PRD's dir"                       test -e "$(G 193)"
assert_ok "sweep keeps the open PRD's dir"                           test -d "$(G 194)"
assert_ok "sweep keeps a dir whose state it could not read"          test -d "$(G 195)"
assert_ok "sweep leaves a dir that is not a PRD's"                   test -d "$STATE_DIR/gauntlet/$UNIT/notaprd"
finish
