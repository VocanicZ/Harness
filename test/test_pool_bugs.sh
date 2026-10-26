#!/usr/bin/env bash
# test_pool_bugs.sh — #214: a pool worker with no dispatchable impl work takes the oldest open bug
# of its unit's repo while the priority lane is busy. The two lanes share one claim file per bug,
# so a bug either lane holds is never offered to the other.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; SLUG="acme/widget"; UNIT=main
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
claim_of(){ cat "$CLAIMS_DIR/bug-acme_widget-$1.claim" 2>/dev/null; }

echo "-- claims: either lane's hold keeps the bug from the other"
printf 'P1 %s acme/widget#30\n' "$$" > "$CLAIMS_DIR/bug-acme_widget-30.claim"   # the lane holds #30
assert_no "pool cannot claim a bug the lane holds" claim_bug pool-main "acme/widget#30"
assert_eq "$(awk '{print $1}' <<<"$(claim_of 30)")" "P1" "the lane's claim is untouched"
assert_ok "pool claims a free bug" claim_bug pool-main "acme/widget#31"
assert_eq "$(claim_of 31)" "pool-main $$ acme/widget#31" "pool claim names its unit, pid and ref"
_bug_numbers(){ printf 'acme/widget#30\nacme/widget#31\nacme/widget#32\n'; }
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/widget#32 " "the lane is never offered a bug the pool holds"
assert_no "a second pool claim on the same bug is refused" claim_bug pool-other "acme/widget#31"
assert_eq "$(lane_bug)" "acme/widget#30" "lane_bug reports the lane's bug, not the pool's"
assert_eq "$(pool_bug_claims main | cut -f2)" "acme/widget#31" "pool_bug_claims lists the unit's pool claims"
assert_eq "$(pool_bug_claims other)" "" "...and only that unit's"
assert_eq "$(count_pool_bugs main)" "1" "a live pool claim holds one of the unit's slots"
rm -f "$CLAIMS_DIR"/bug-*.claim

echo "-- priority_free_slots"
assert_eq "$(priority_free_slots)" "0" "no lane running → no free priority slot (the pool takes the bugs)"
echo "$$" > "$RUN_DIR/priority.pid"
assert_eq "$(priority_free_slots)" "1" "lane up and idle → one free slot"
printf 'pool-main %s acme/widget#31\n' "$$" > "$CLAIMS_DIR/bug-acme_widget-31.claim"
assert_eq "$(priority_free_slots)" "1" "a pool-held bug does not occupy the lane"
printf 'P1 %s acme/widget#30\n' "$$" > "$CLAIMS_DIR/bug-acme_widget-30.claim"
assert_eq "$(priority_free_slots)" "0" "lane holding a bug → busy"
rm -f "$CLAIMS_DIR"/bug-*.claim "$RUN_DIR/priority.pid"

echo "-- dispatch_actions passes --priority-free only when HARNESS_POOL_TAKES_BUGS=1"
STUB="$RUN_DIR/issuelib-stub.py"; printf 'import sys; print(" ".join(sys.argv[1:]))\n' > "$STUB"
REAL_ISSUELIB="$ISSUELIB"; ISSUELIB="$STUB"
HARNESS_POOL_TAKES_BUGS=1
assert_eq "$(dispatch_actions acme/widget 2 1 '')" \
  "dispatch acme/widget 2 --allow-orchestration 1 --busy-prds  --priority-free 0" "knob on → lane's free slots passed"
HARNESS_POOL_TAKES_BUGS=0
assert_eq "$(dispatch_actions acme/widget 2 1 '')" \
  "dispatch acme/widget 2 --allow-orchestration 1 --busy-prds " "knob off → bugs stay on the lane"
HARNESS_POOL_TAKES_BUGS=1; ISSUELIB="$REAL_ISSUELIB"

echo "-- spawn_pool_bug: the lane's spawn, claimed first, then held by the session's pane"
SPAWNED=""; PANE=""
spawn_bug(){ SPAWNED+="$1:$2 "; }
bug_phase(){ echo triage; }
tmux(){ [[ "$1" == display-message && -n "$PANE" ]] && echo "$PANE"; return 0; }
sleep 600 & PANE=$!
spawn_pool_bug 31 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "spawn_pool_bug succeeds"
assert_eq "$SPAWNED" "31:triage " "the lane's spawn_bug ran for the bug's current phase"
assert_eq "$(claim_of 31)" "pool-main $PANE acme/widget#31" "claim handed to the session's pane pid"
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/widget#30 acme/widget#32 " "lane skips it while the session lives"
kill "$PANE" 2>/dev/null; wait "$PANE" 2>/dev/null
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/widget#30 acme/widget#31 acme/widget#32 " "session gone → the lane can take the next phase"
rm -f "$CLAIMS_DIR"/bug-*.claim

SPAWNED=""
printf 'P1 %s acme/widget#30\n' "$$" > "$CLAIMS_DIR/bug-acme_widget-30.claim"
spawn_pool_bug 30 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "a bug the lane already claimed is refused"
assert_eq "$SPAWNED" "" "...and never spawned"
rm -f "$CLAIMS_DIR"/bug-*.claim

spawn_bug(){ return 1; }
spawn_pool_bug 31 >/dev/null 2>&1
assert_eq "$(claim_of 31)" "" "a failed spawn releases the claim"
spawn_bug(){ :; }; PANE=""
spawn_pool_bug 31 >/dev/null 2>&1
assert_eq "$(claim_of 31)" "" "no session came up → claim released"

echo "-- reap_pool_bugs"
REMOVED=""; KILLED=""; LIVE=""
remove_worktree(){ REMOVED+="${2##*/}:$3 "; }
session_live(){ [[ " $LIVE " == *" $1 "* ]]; }
watchdog_session(){ :; }
stats_sweep_ended(){ :; }
tmux(){ [[ "$1" == kill-session ]] && KILLED+="$3 "; return 0; }
GOAL_DONE=1; bug_goal_done(){ (( GOAL_DONE == 0 )); }
TRI="$(sess_bug acme/widget 31 triage)"

# live session whose goal is not met yet: left alone
sleep 600 & HOLD=$!
printf 'pool-main %s acme/widget#31\n' "$HOLD" > "$CLAIMS_DIR/bug-acme_widget-31.claim"
LIVE="$TRI"
reap_pool_bugs >/dev/null 2>&1
assert_eq "$KILLED$REMOVED" "" "a working session is left running"
assert_ok "...and keeps its claim" test -f "$CLAIMS_DIR/bug-acme_widget-31.claim"
# goal met: the session is ended
GOAL_DONE=0
reap_pool_bugs >/dev/null 2>&1
assert_eq "$KILLED" "$TRI " "goal met → session ended"
# session gone: worktrees + claim released
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; LIVE=""
reap_pool_bugs >/dev/null 2>&1
assert_eq "$REMOVED" "bug-acme_widget-i31:issue/31 triage-acme_widget-i31:agent/bug-triage-31 " "both phase worktrees reaped"
assert_eq "$(claim_of 31)" "" "stale pool claim dropped"
# a claim the lane took over meanwhile is not the pool's to reap
REMOVED=""
printf 'P1 999999 acme/widget#31\n' > "$CLAIMS_DIR/bug-acme_widget-31.claim"
reap_pool_bugs >/dev/null 2>&1
assert_eq "$REMOVED" "" "a lane-owned claim is never reaped by the pool"
rm -f "$CLAIMS_DIR"/bug-*.claim

echo "-- drive_unit routes BUG to spawn_pool_bug and counts pool bugs against CAP"
write_targets <<'EOF'
main	acme/widget	-	root
EOF
GOT=""; FREE="$RUN_DIR/free"; : > "$FREE"
spawn_pool_bug(){ GOT+="BUG:$1 "; }
spawn_impl(){ :; }; spawn_orch(){ :; }; close_prd(){ :; }
reap_done_sessions(){ :; }; reap_team(){ :; }; reap_orch(){ :; }; watchdog_team(){ :; }
reap_finished_inject(){ :; }; reap_pool_bugs(){ :; }; retry_pending_unlocks(){ :; }; sweep_orphan_locks(){ :; }
ci_gate_ok(){ return 0; }; usage_watch(){ :; }; usage_held(){ return 1; }; gh_budget_low(){ return 1; }
gh_rate_wait(){ :; }; team_sessions(){ :; }; count_team_sessions(){ echo 0; }; git(){ :; }
count_pool_bugs(){ echo 1; }
dispatch_actions(){ echo "$2" >> "$FREE"; printf 'BUG\t30\tBUG 30 DONE\n'; }
CAP=2; POLL=0; _PASSES=0
unit_complete(){ _PASSES=$((_PASSES+1)); (( _PASSES > 1 )); }
drive_unit main >/dev/null 2>&1
assert_eq "$GOT" "BUG:30 " "BUG action spawned through spawn_pool_bug"
assert_eq "$(cat "$FREE")" "1" "a live pool bug takes one of the unit's CAP slots"

finish
