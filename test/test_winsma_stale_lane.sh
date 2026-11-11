#!/usr/bin/env bash
# test_winsma_stale_lane.sh — #1050: a lane whose branch predates the winsma protocol check (#1041: ws_proto_check in
# test/smoke/winsma/lock.sh) runs no check and polls for ever beside the FIFO queue. The engine cannot stop that lane from the
# host, so it stops it BEFORE it queues: a live lane is told once to rebase (winsma_stale_tick), a lane (re)launched on a pushed
# branch that predates the check gets a rebase order in its task file (winsma_prelaunch_notice). Real git repos, stub gh/cli_send.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
export HARNESS_WINDOWS_HOST=winsma-fake HARNESS_WINSMA_STALE_S=0
SLUG=acme/widget; UNIT=main
CALLS="$RUN_DIR/calls"; : > "$CALLS"
log(){ echo "log $*" >> "$CALLS"; }
harness_event(){ echo "event $*" >> "$CALLS"; }
cli_send(){ echo "send $1 :: $3" >> "$CALLS"; }
session_live(){ return 0; }
sess_list(){ printf '%s\n' "$SESSIONS"; }
default_branch(){ echo main; }

# A bare origin whose main has the check; a branch cut before it (issue/777) has an old lock.sh.
O="$RUN_DIR/origin.git"; C="$RUN_DIR/seed"
git init -q --bare -b main "$O"; git clone -q "$O" "$C" 2>/dev/null; git -C "$C" config user.email t@t; git -C "$C" config user.name t
mkdir -p "$C/test/smoke/winsma"
printf 'ws_lock(){ :; }\n' > "$C/test/smoke/winsma/lock.sh"; git -C "$C" add -A; git -C "$C" commit -qm old; git -C "$C" push -q origin HEAD:main
git -C "$C" checkout -q -b issue/777; echo wip > "$C/wip.txt"; git -C "$C" add -A; git -C "$C" commit -qm wip; git -C "$C" push -q origin issue/777
git -C "$C" checkout -q main; printf 'ws_proto_check(){ :; }\nws_lock(){ ws_proto_check; }\n' > "$C/test/smoke/winsma/lock.sh"
git -C "$C" commit -qam "#1041 check"; git -C "$C" push -q origin main

wt(){ local n="$1" br="$2"; rm -rf "$RUN_DIR/wt$n"; git clone -q "$O" "$RUN_DIR/wt$n" 2>/dev/null; git -C "$RUN_DIR/wt$n" checkout -q "$br"; echo "$RUN_DIR/wt$n"; }
mksess(){ echo "$2" > "$RUN_DIR/$1.wd"; }

echo "=== 1. winsma_code_stale reads the lane's lock code ==="
OLD="$(wt 1 issue/777)"; NEW="$(wt 2 main)"
assert_ok "a worktree whose lock.sh has no ws_proto_check is stale" winsma_code_stale "$OLD"
assert_no "a worktree on main (has the check) is current" winsma_code_stale "$NEW"
assert_ok "a ref whose lock.sh has no check is stale" winsma_code_stale "$NEW" origin/issue/777
assert_no "no winsma helpers at all: nothing streams, not stale" winsma_code_stale "$RUN_DIR"

echo "=== 2. a live lane on old code is told to rebase, once, before it queues ==="
S1="$HARNESS_SESS_PREFIX-main-i777"; S2="$HARNESS_SESS_PREFIX-main-i888"; SESSIONS="$S1"$'\n'"$S2"
mksess "$S1" "$OLD"; mksess "$S2" "$NEW"
winsma_stale_tick
assert_eq "$(grep -c "^send $S1 :: .*git rebase origin/main" "$CALLS")" "1" "the stale lane is sent the rebase order"
assert_ok "...which says to stop before any winsma.sh step" grep -q "^send $S1 :: .*STOP before any winsma.sh step" "$CALLS"
assert_no "a current lane is left alone" grep -q "^send $S2 " "$CALLS"
winsma_stale_tick
assert_eq "$(grep -c "^send $S1 " "$CALLS")" "1" "the order is sent once, not every tick"
git -C "$OLD" fetch -q origin; git -C "$OLD" rebase -q origin/main 2>/dev/null
winsma_stale_tick
assert_no "a lane that rebased clears its marker" test -f "$RUN_DIR/$S1.winsma-stale"
assert_eq "$(grep -c "^send $S1 " "$CALLS")" "1" "...and is not told again"
( unset HARNESS_WINDOWS_HOST; git -C "$OLD" checkout -q origin/issue/777 2>/dev/null; : > "$CALLS"; rm -f "$RUN_DIR/$S1.winsma-stale"; winsma_stale_tick
  assert_eq "$(grep -c '^send ' "$CALLS")" "0" "no Windows host: no check, no message" )

echo "=== 3. a (re)launch onto a pushed branch cut before the check gets the order in its task file ==="
: > "$CALLS"; FRESH="$(wt 3 main)"; : > "$FRESH/.harness-task.md"; echo "base task" > "$FRESH/.harness-task.md"
winsma_prelaunch_notice "$FRESH" issue/777 main; rc=$?
assert_eq "$rc" "0" "origin/issue/777 predates the check: a notice is written"
assert_ok "the task file orders a rebase first" grep -q 'REBASE FIRST' "$FRESH/.harness-task.md"
assert_ok "...naming the base" grep -q 'git rebase origin/main' "$FRESH/.harness-task.md"
assert_ok "...and keeps the original task" grep -q 'base task' "$FRESH/.harness-task.md"
echo "base task" > "$FRESH/.harness-task.md"
winsma_prelaunch_notice "$FRESH" issue/999 main; rc=$?
assert_eq "$rc" "1" "a fresh branch (no pushed copy; worktree is main) is current: no notice"
assert_no "...task file untouched" grep -q 'REBASE FIRST' "$FRESH/.harness-task.md"
HARNESS_WINDOWS_HOST= winsma_prelaunch_notice "$FRESH" issue/777 main; assert_eq "$?" "1" "no Windows host: no notice"

echo "=== 4. the engine runs both checks ==="
assert_ok "worker_chores runs winsma_stale_tick" grep -q '^  winsma_stale_tick' "$HERE/../scripts/pool-worker.sh"
assert_ok "prepare_impl runs winsma_prelaunch_notice before the launch" grep -q 'winsma_prelaunch_notice "\$wd" "\$branch" "\$base"' "$HERE/../scripts/drive.sh"
finish
