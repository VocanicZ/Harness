#!/usr/bin/env bash
# test_pool_lanes.sh — #468 (PRD #464 §2): the step-based pool worker. A worker claims ONE lane (one issue or
# one PRD action), runs it, reaps it, releases it; POOL is the most lanes that run at once.
#   1. POOL=3, three ready issues → three impl lanes at once, one per worker; no issue claimed twice, nor a
#      PRD's one DECOMPOSE item by two workers in the same second.
#   2. one ready issue → one lane, the others idle; none ready → all idle; the POOL cap holds.
#   3. chores run every tick while every worker is busy (POOL=1: a live lane, a LABEL_READY, an inject loop).
#   4. a killed worker's lane is adopted, reaped and released once; no duplicate dispatch; start --recover.
#   5. planned mode: PLAN.md archived once on completion, no lane touched, nothing dispatched.
#   6. the priority bug worker runs on top of POOL, and a pool-taken bug is never also its claim.
#   7. pause: no new claim, a running lane (and a driven goal loop) still tended.
# Real issuelib.py dispatch over a snapshot; gh, tmux, git and the launch are stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"; source "$HERE/../scripts/priority-worker.sh"; source "$HERE/helpers.sh"

# snap <num[:labels,csv]>… — the poller's view of the board; each issue is open, bot-authored.
snap(){ python3 - "$SNAP" "$@" <<'EOF'
import json, sys, time
path, specs = sys.argv[1], sys.argv[2:]
issues = []
for s in specs:
    n, _, labels = s.partition(":")
    body = "## What to build\nx\n" if "prd" not in labels.split(",") else "## Problem\nx\n"
    issues.append({"number": int(n), "title": f"t{n}", "state": "OPEN", "body": body,
                   "labels": [{"name": l} for l in labels.split(",") if l],
                   "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"})
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget",
           "issues": issues, "has_plan": False, "plan_marker": None, "self_login": "bot",
           "ext_deps": {}, "issue_branches": []}, open(path, "w"))
EOF
}

# restore — the real functions again: a section stubs them, the next one starts from the sources.
restore(){ source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/../scripts/pool-worker.sh"
  source "$HERE/../scripts/priority-worker.sh"; }
setup(){  # [pool]
  restore; make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; HARNESS_UNIT=""
  POOL="${1:-3}"; POLL=0; HARNESS_USE_POLLER=0; HARNESS_CHECKOUT="$RUN_DIR/co"; mkdir -p "$HARNESS_CHECKOUT"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude HARNESS_CI_GATE=0
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LIVE="$RUN_DIR/live"; : > "$LIVE"; LOGF="$RUN_DIR/log"; : > "$LOGF"
  EVENTS="$RUN_DIR/events"; : > "$EVENTS"; HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"; export HARNESS_EVENTS_FILE CALLS LIVE
  gh(){ echo "gh $*" >> "$CALLS"
        case "$*" in
          *"issue view"*"state,labels"*) echo '{"state":"OPEN","labels":[]}';;
          *"issue view"*) echo '[]';;
        esac; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS"
          case "$1" in has-session) grep -qxF "$3" "$LIVE";; ls|list-sessions) cat "$LIVE";; esac; }
  export -f gh tmux
  git(){ case "$*" in
           *"worktree add"*) local wd; for wd in "$@"; do [[ "$wd" == "$WORKTREES_DIR"/* ]] && break; done
                             [[ -d "$wd" ]] && return 128; mkdir -p "$wd"; return 0;;
           *"worktree remove"*|*"branch -D"*) echo "git $*" >> "$CALLS"; return 0;;
         esac; return 0; }
  log(){ echo "$*" >> "$LOGF"; }
  render(){ :; }
  launch_claude(){ echo "launch $1" >> "$CALLS"; echo "$1" >> "$LIVE"; }
  ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }; default_branch(){ echo main; }
  resume_handoff(){ :; }; issue_parent_prd(){ :; }; stats_sweep_ended(){ :; }; gc_orphan_goals(){ :; }
  remove_worktree(){ echo "remove_worktree $2" >> "$CALLS"; rm -rf "$2"; }
  gh_rate_wait(){ :; }; usage_watch(){ :; }; usage_held(){ return 1; }; gh_budget_low(){ return 1; }
  seed_if_needed(){ :; }; roots_check(){ :; }; snapshot_gate(){ return 0; }
  release_tick(){ :; }; retry_pending_unlocks(){ :; }; sweep_orphan_locks(){ :; }; one_auto_tend(){ :; }
  reap_finished_inject(){ :; }; unlock_issue(){ echo "unlock $2" >> "$CALLS"; }; release_on_bug_merge(){ :; }
  watchdog_session(){ echo "watchdog $1" >> "$CALLS"; }; check_session_goal(){ echo "goal $1" >> "$CALLS"; }
  sleep(){ :; }
  COMPLETE=0; unit_complete(){ (( COMPLETE )); }
}
# Where a lane's session or worktree is — the way a launched lane leaves them.
live(){ local s; for s in "$@"; do echo "$s" >> "$LIVE"; done; }
die_session(){ grep -vxF "$1" "$LIVE" > "$LIVE.n"; mv "$LIVE.n" "$LIVE"; }
launches(){ grep -c "^launch " "$CALLS"; }
# inctx <cmd…> — run a drive.sh helper in the dynamic scope a worker step gives it (UNIT, SLUG, CHECKOUT…).
inctx(){ local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx; "$@"; }
claim_wid(){ awk '{print $1}' "$CLAIMS_DIR/$1.claim" 2>/dev/null; }

echo "=== 1. POOL=3, three ready issues: three lanes at once, one per worker ==="
setup 3; snap "5:ready-for-agent" "6:ready-for-agent" "7:ready-for-agent"
worker_tick W1; assert_eq "$?" "0" "W1 claimed + spawned"
worker_tick W2; assert_eq "$?" "0" "W2 claimed + spawned"
worker_tick W3; assert_eq "$?" "0" "W3 claimed + spawned"
assert_eq "$(launches)" "3" "three impl lanes launched"
assert_eq "$(sort "$LIVE" | tr '\n' ' ')" "hz-main-i5 hz-main-i6 hz-main-i7 " "one lane per ready issue"
assert_eq "$(claim_wid impl-5)/$(claim_wid impl-6)/$(claim_wid impl-7)" "W1/W2/W3" "each issue owned by a different worker"
assert_eq "$(awk '{print $3, $4}' "$CLAIMS_DIR/impl-5.claim")" "IMPL:5 hz-main-i5" "claim keeps <wid> <pid> <token> and appends the session"
assert_eq "$(awk '{print NF}' "$CLAIMS_DIR/impl-5.claim")" "5" "... and the pane pid"
assert_eq "$(pool_lane_count)" "3" "three lanes live"
assert_ok "lane_claim events carry the repo and the worker" grep -q '"event": "lane_claim".*"worker": "W1"' "$HARNESS_EVENTS_FILE"
assert_ok "lane_claim events carry the repo" grep -q '"event": "lane_claim".*"repo": "acme/widget"' "$HARNESS_EVENTS_FILE"
worker_tick W1; assert_eq "$?" "1" "a worker that owns a lane claims nothing more"

echo "=== 1b. a fourth issue waits: POOL caps the fleet, even for a worker with no lane ==="
snap "5:ready-for-agent,agent-working" "6:ready-for-agent,agent-working" "7:ready-for-agent,agent-working" "8:ready-for-agent"
worker_tick W4; assert_eq "$?" "1" "W4 finds POOL lanes live: no claim"
assert_eq "$(launches)" "3" "still three lanes"

echo "=== 1c. three claimers in the same second: no issue taken twice ==="
setup 3; snap "5:ready-for-agent" "6:ready-for-agent" "7:ready-for-agent"
for w in W1 W2 W3; do ( worker_tick "$w" ) & done; wait
assert_eq "$(launches)" "3" "three lanes from three simultaneous claimers"
assert_eq "$(sort "$LIVE" | uniq | wc -l | tr -d ' ')" "3" "three distinct sessions"
assert_eq "$(for k in impl-5 impl-6 impl-7; do claim_wid $k; done | sort | tr '\n' ' ')" "W1 W2 W3 " "three different owners"

echo "=== 1d. a PRD's single DECOMPOSE item, two workers at once: claimed once ==="
setup 3; export HARNESS_MODE=prd; snap "41:prd"
for w in W1 W2 W3; do ( worker_tick "$w" ) & done; wait
assert_eq "$(launches)" "1" "DECOMPOSE launched exactly once"
assert_ok "... as the PRD's orch session" grep -qx "hz-main-p41" "$LIVE"
assert_eq "$(ls "$CLAIMS_DIR"/orch-*.claim | wc -l | tr -d ' ')" "1" "one orch claim"
assert_eq "$(awk '{print $3}' "$CLAIMS_DIR/orch-41.claim")" "DECOMPOSE:41" "the claim names the action"
assert_eq "$(claimed_prds)" "41" "claimed_prds reads it"

echo "=== 2. one ready issue: one lane, the other workers idle; none ready: all idle ==="
setup 3; snap "5:ready-for-agent"
worker_tick W1; worker_tick W2; rc2=$?; worker_tick W3; rc3=$?
assert_eq "$(launches)" "1" "one lane"
assert_eq "$rc2/$rc3" "1/1" "W2 and W3 idle (rc 1)"
setup 3; snap "5:ready-for-agent,agent-working"
worker_tick W1; rc=$?; assert_eq "$rc" "1" "nothing claimable: idle"
assert_eq "$(launches)" "0" "no lane"
COMPLETE=1; worker_tick W1; assert_eq "$?" "2" "a COMPLETE repo: rc 2 (idle, resident)"

echo "=== 2b. a free slot is never left while an item is claimable ==="
setup 2; snap "5:ready-for-agent" "6:ready-for-agent" "7:ready-for-agent"
worker_tick W1; worker_tick W2; worker_tick W3; rc=$?
assert_eq "$(launches)" "2" "POOL=2 runs two lanes"
assert_eq "$rc" "1" "the third worker waits"
die_session hz-main-i5; worker_tend W1; assert_eq "$?" "0" "W1's lane ended: reaped"
snap "6:ready-for-agent,agent-working" "7:ready-for-agent"   # #5 merged: it is off the board
assert_no "... and its claim released" test -f "$CLAIMS_DIR/impl-5.claim"
worker_tick W1; assert_eq "$?" "0" "the freed slot is taken at once"
assert_ok "... by the next issue" grep -qx "hz-main-i7" "$LIVE"

echo "=== 3. chores run every tick while every worker is busy (POOL=1) ==="
setup 1; snap "5:ready-for-agent" "9:"
worker_tick W1
CHORES="$RUN_DIR/chores"; : > "$CHORES"
label_ready(){ echo "label $1" >> "$CHORES"; }
reap_finished_inject(){ echo "inject-loop $1" >> "$CHORES"; }
reap_team(){ echo reap_team >> "$CHORES"; }; reap_orch(){ echo reap_orch >> "$CHORES"; }
reap_done_sessions(){ echo reap_done >> "$CHORES"; }; watchdog_team(){ echo watchdog >> "$CHORES"; }
dispatch_actions(){ [[ "$2" == 99 ]] && printf 'LABEL_READY\t9\t-\nCLOSE_PRD\t41\tPRD CLOSED\n'; return 0; }
close_prd(){ echo "close $1" >> "$CHORES"; }
worker_step W1; rc=$?
assert_eq "$rc" "1" "the busy worker claims nothing more (rc 1)"
assert_ok "LABEL_READY advanced" grep -qx "label 9" "$CHORES"
assert_ok "CLOSE_PRD advanced" grep -qx "close 41" "$CHORES"
assert_ok "the inject goal loop was ticked" grep -qx "inject-loop main" "$CHORES"
assert_ok "the reapers ran" grep -qx reap_team "$CHORES"
assert_ok "the live lane was tended by its owner" grep -qx "goal hz-main-i5" "$CALLS"
assert_ok "... and watchdogged" grep -qx "watchdog hz-main-i5" "$CALLS"
echo "-- one winner per tick: a worker that does not win chores.lock skips them"
: > "$CHORES"; exec 8>"$RUN_DIR/chores.lock"; flock -n 8
worker_chores W2; assert_eq "$(cat "$CHORES")" "" "chores.lock held elsewhere: none ran"
exec 8>&-
worker_chores W2; assert_ok "free again: they ran" grep -qx reap_team "$CHORES"
: > "$CHORES"; worker_step W1 >/dev/null
assert_eq "$(grep -c '^reap_team$' "$CHORES")" "1" "chores ran once in a tick of one worker"

echo "=== 3b. only ownerless lanes are reaped/checked/watchdogged by the chores ==="
setup 3; snap "5:ready-for-agent" "6:ready-for-agent"
worker_tick W1; mkdir -p "$WORKTREES_DIR/main-i6"; live hz-main-i6   # #6: a live lane nobody owns
inctx reap_done_sessions; inctx watchdog_team
assert_no "the owned lane #5 is left to its owner (goal)" grep -qx "goal hz-main-i5" "$CALLS"
assert_no "... and watchdog" grep -qx "watchdog hz-main-i5" "$CALLS"
assert_ok "the ownerless lane #6 is checked" grep -qx "goal hz-main-i6" "$CALLS"
assert_ok "... and watchdogged" grep -qx "watchdog hz-main-i6" "$CALLS"
die_session hz-main-i5; : > "$CALLS"; inctx reap_team
assert_no "a dead lane with a LIVE claim is left to its owner (no reap)" grep -q 'remove_worktree .*main-i5' "$CALLS"
worker_tend W1; assert_eq "$?" "0" "the owner reaps it"
assert_ok "... removing the worktree" grep -q 'remove_worktree .*main-i5' "$CALLS"
assert_no "... and releases the claim" test -f "$CLAIMS_DIR/impl-5.claim"

echo "=== 4. a killed worker: its lane is adopted, reaped once, never dispatched twice ==="
setup 2; snap "5:ready-for-agent,agent-working" "6:ready-for-agent"
live hz-main-i5; mkdir -p "$WORKTREES_DIR/main-i5"
echo "echo $(printf 'W1 999999 IMPL:5 hz-main-i5 -')" > /dev/null
printf 'W1 999999 IMPL:5 hz-main-i5 -\n' > "$CLAIMS_DIR/impl-5.claim"   # W1 died: its pid is gone
assert_no "a dead worker's claim is no claim" is_claimed impl-5
assert_eq "$(pool_lane_count)" "1" "the lane still counts (its session is live)"
worker_chores W2
assert_eq "$(claim_wid impl-5)" "W2" "W2 adopted the lane"
assert_eq "$(awk '{print $2}' "$CLAIMS_DIR/impl-5.claim")" "$$" "... under its own pid"
assert_ok "adoption is logged" grep -q 'adopted lane impl-5' "$LOGF"
assert_ok "lane_adopt event carries the worker" grep -q '"event": "lane_adopt".*"worker": "W2"' "$HARNESS_EVENTS_FILE"
worker_tick W3; assert_eq "$?" "0" "a second slot is free: W3 takes #6, not #5"
assert_eq "$(launches)" "1" "no duplicate dispatch of #5 (one launch: #6)"
assert_ok "... #6" grep -qx "launch hz-main-i6" "$CALLS"
worker_chores W3
assert_eq "$(claim_wid impl-5)" "W2" "an owned lane is not re-adopted"
echo "-- the session ends: reaped once, released once"
snap "5:ready-for-agent,agent-working" "6:ready-for-agent,agent-working"
die_session hz-main-i5
worker_chores W3; worker_tend W2; worker_tend W2
assert_eq "$(grep -c 'remove_worktree .*main-i5' "$CALLS")" "1" "the worktree was reaped exactly once"
assert_no "the claim is released" test -f "$CLAIMS_DIR/impl-5.claim"
assert_eq "$(grep -c '^unlock 5$' "$CALLS")" "1" "the issue was freed exactly once"

echo "-- start --recover: clear_stale_claims drops the claims, the live lanes are adopted from their sessions"
setup 3; snap "5:ready-for-agent,agent-working" "6:ready-for-agent,agent-working"
live hz-main-i5 hz-main-p41; mkdir -p "$WORKTREES_DIR/main-i5"; echo "DECOMPOSE:41" > "$RUN_DIR/hz-main-p41.goal"
printf 'W1 999999 IMPL:5 hz-main-i5 -\n' > "$CLAIMS_DIR/impl-5.claim"; printf 'W2 999998 DECOMPOSE:41 hz-main-p41 -\n' > "$CLAIMS_DIR/orch-41.claim"
clear_stale_claims >/dev/null
assert_eq "$(ls "$CLAIMS_DIR" | wc -l | tr -d ' ')" "0" "recover cleared the stale claims"
assert_eq "$(pool_lane_count)" "2" "both lanes are still counted from their sessions"
worker_chores W1
assert_eq "$(claim_wid impl-5)/$(claim_wid orch-41)" "W1/W1" "one worker adopted both lanes (adoption can add more)"
assert_eq "$(awk '{print $3}' "$CLAIMS_DIR/orch-41.claim")" "DECOMPOSE:41" "the orch claim keeps the action from the goal"
assert_eq "$(launches)" "0" "nothing relaunched"
worker_tick W2; assert_eq "$?" "1" "no ready issue left: W2 idle (a lane's issue is not dispatched again)"
echo "-- a stale claim with no lane behind it is swept"
printf 'W9 999999 IMPL:77 hz-main-i77 -\n' > "$CLAIMS_DIR/impl-77.claim"; worker_chores W1
assert_no "stale impl-77 claim swept" test -f "$CLAIMS_DIR/impl-77.claim"

echo "-- a dead lane's worktree is reaped, by the chores, once its session is gone"
setup 3; snap "5:ready-for-agent,agent-working"
mkdir -p "$WORKTREES_DIR/main-i5" "$WORKTREES_DIR/orch-acme_widget-p41"
worker_chores W1
assert_no "the impl worktree is gone" test -d "$WORKTREES_DIR/main-i5"
assert_no "the orch worktree is gone" test -d "$WORKTREES_DIR/orch-acme_widget-p41"
assert_eq "$(grep -c '^unlock 5$' "$CALLS")" "1" "its issue was freed"

echo "=== 5. planned mode: PLAN.md archived once on completion; nothing else touched ==="
setup 3; export HARNESS_MODE=planned; SPECFILE="$RUN_DIR/spec.md"; printf 's\n' > "$SPECFILE"; HARNESS_SPEC="$SPECFILE"
snap "5:ready-for-agent,agent-working"
printf '# plan\n' > "$HARNESS_CHECKOUT/PLAN.md"; git(){ return 1; }
live hz-main-i5; mkdir -p "$WORKTREES_DIR/main-i5"; printf 'W1 %s IMPL:5 hz-main-i5 -\n' "$$" > "$CLAIMS_DIR/impl-5.claim"
dispatch_actions(){ echo "dispatch $*" >> "$CALLS"; return 0; }; spawn_orch(){ echo "spawn_orch $*" >> "$CALLS"; }
COMPLETE=1
worker_chores W1; worker_chores W2
assert_no "PLAN.md left the repo root" test -f "$HARNESS_CHECKOUT/PLAN.md"
assert_eq "$(ls "$HARNESS_CHECKOUT"/docs/harness/archive/PLAN-*.md | wc -l | tr -d ' ')" "1" "archived exactly once"
assert_ok "the completion marker is written" test -f "$HARNESS_CHECKOUT/docs/harness/plan-complete.json"
assert_no "no dispatch on a COMPLETE repo (the PRD action does not fire again)" grep -q '^dispatch ' "$CALLS"
assert_no "no orch lane spawned" grep -q '^spawn_orch' "$CALLS"
assert_eq "$(claim_wid impl-5)" "W1" "a lane holding a claim is untouched"
assert_ok "... its session still live" grep -qx hz-main-i5 "$LIVE"
assert_no "no kill-all (finalize_unit)" grep -q 'kill-session' "$CALLS"
worker_tick W2; assert_eq "$?" "2" "the worker reports COMPLETE (rc 2), stays resident"

echo "=== 6. the priority bug worker runs on top of POOL; a pool-taken bug is never also its claim ==="
setup 1; export HARNESS_POOL_TAKES_BUGS=1; snap "8:bug" "9:bug"
# the priority lane is up and holds bug #8: no free priority slot, so the pool may spill into bugs
command sleep 60 & PRIO=$!; echo "$PRIO" > "$RUN_DIR/priority.pid"
printf 'P1 %s acme/widget#8\n' "$PRIO" > "$CLAIMS_DIR/bug-acme_widget-8.claim"
assert_eq "$(pool_lane_count)" "0" "the priority lane's bug is not one of POOL's lanes"
spawn_bug(){ echo "spawn_bug $*" >> "$CALLS"; live "hz-bug-acme_widget-$1-$2"; }
_bug_numbers(){ echo "acme/widget#9"; }; bug_phase(){ echo triage; }
worker_tick W1; assert_eq "$?" "0" "the idle pool slot took a bug"
assert_ok "... #9 (not the lane's #8)" grep -q '^spawn_bug 9 triage' "$CALLS"
assert_eq "$(claim_wid bug-acme_widget-9)" "pool-W1" "claimed as pool-<wid> (never mistaken for the lane's claim)"
assert_eq "$(lane_bug)" "acme/widget#8" "lane_bug still names only the priority lane's bug"
assert_eq "$(claimable_bugs | tr '\n' ' ')" "" "the priority lane cannot claim the pool's bug"
assert_eq "$(pool_lane_count)" "1" "the pool's bug is one of POOL's lanes"
worker_tick W2; assert_eq "$?" "1" "POOL=1: no second lane"
kill "$PRIO" 2>/dev/null; wait "$PRIO" 2>/dev/null
echo "-- the owner tends the bug's session and reaps it when it is gone"
bug_goal_done(){ return 1; }; : > "$CALLS"
worker_tend W1; assert_eq "$?" "1" "live bug session: tended, not reaped"
assert_ok "... watchdogged" grep -q 'watchdog hz-bug-acme_widget-9-triage' "$CALLS"
die_session hz-bug-acme_widget-9-triage
worker_tend W1; assert_eq "$?" "0" "gone: reaped"
assert_no "claim released" test -f "$CLAIMS_DIR/bug-acme_widget-9.claim"
assert_ok "bug worktrees removed" grep -q 'remove_worktree .*bug-acme_widget-i9' "$CALLS"
echo "-- a pool bug whose worker died is tended by the chores"
live hz-bug-acme_widget-9-fix; printf 'pool-W1 999999 acme/widget#9 hz-bug-acme_widget-9-fix -\n' > "$CLAIMS_DIR/bug-acme_widget-9.claim"
: > "$CALLS"; reap_ownerless_pool_bugs
assert_ok "live: watchdogged by the chores" grep -q 'watchdog hz-bug-acme_widget-9-fix' "$CALLS"
assert_ok "... and not reaped" test -f "$CLAIMS_DIR/bug-acme_widget-9.claim"
die_session hz-bug-acme_widget-9-fix; reap_ownerless_pool_bugs
assert_no "gone: claim released by the chores" test -f "$CLAIMS_DIR/bug-acme_widget-9.claim"

echo "=== 7. pause: no new claim; a running lane (and a driven goal loop) keeps being tended ==="
setup 3; snap "5:ready-for-agent" "6:ready-for-agent"
worker_tick W1; : > "$CALLS"
touch "$PAUSE_FLAG"
worker_step W2; assert_eq "$?" "3" "paused: no claim (rc 3)"
assert_eq "$(launches)" "0" "nothing launched while paused"
worker_tend W1
assert_ok "W1's running lane is still tended" grep -qx 'goal hz-main-i5' "$CALLS"
assert_ok "... through the watchdog (which drives a goal loop)" grep -qx 'watchdog hz-main-i5' "$CALLS"
assert_eq "$(claim_wid impl-6)" "" "no claim for #6"
rm -f "$PAUSE_FLAG"

finish
