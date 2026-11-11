#!/usr/bin/env bash
# test_closed_reclaim.sh — #730: the pool must not re-claim an issue that just closed while the board snapshot still
# lists it OPEN + ready-for-agent (the poller lags up to HARNESS_PRIORITY_POLL, minutes in practice).
#   1. CLAIM GATE: snapshot says #6 is OPEN, live `gh issue view` says CLOSED -> worker_tick launches nothing, adds no
#      worktree, stamps no agent-working, logs no launch_failed; it emits launch_skipped reason=issue_closed, drops the claim.
#   2. NO RE-CLAIM: a second tick claims no #6 and makes no further `gh issue view 6`; another claimable #7 is still taken.
#   3. PREBUILD: a pre-built worktree of #6 is dropped (prebuilt_dropped) when the live state is CLOSED, and not rebuilt.
#   4. GOAL MET AT LAUNCH: a lane whose goal check read DONE and is reaped within 30s of its launch is not a launch_failed
#      and arms no backoff; its session_end carries goal_met=1. A lane that dies young WITHOUT a DONE check still fails.
#   5. OPEN issue: claimed and launched as before, with exactly ONE `gh issue view` in prepare_impl (#618).
#   6. a live-state read that fails (gh error / empty answer) does not block the claim.
#   7. #745: a closed-but-listed #6 beside an open claimable #7: worker_step returns 7 with NO sleep, and the next step
#      launches #7 (no POLL wait). A REAL spawn failure (spawn_impl rc 1) still returns 6 and sleeps POLL (#539).
# Real git (a bare origin + a clone) and the real issuelib.py over a snapshot; gh, tmux and the launch are stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"; source "$HERE/helpers.sh"

snapshot(){ python3 - "$SNAP" "$@" <<'EOF2'
import json, sys, time
path, nums = sys.argv[1], sys.argv[2:]
issues = [{"number": int(n), "title": f"t{n}", "state": "OPEN", "body": "## What to build\nx\n",
           "labels": [{"name": "ready-for-agent"}], "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"} for n in nums]
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget", "issues": issues, "has_plan": False,
           "plan_marker": None, "self_login": "bot", "ext_deps": {}, "issue_branches": []}, open(path, "w"))
EOF2
}

setup(){
  make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; POOL=2; POLL=0
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude HARNESS_CI_GATE=0
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  HARNESS_PREBUILD=1; unset HARNESS_WORKTREE_HOOK
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LIVE="$RUN_DIR/live"; : > "$LIVE"; LOGF="$RUN_DIR/log"; : > "$LOGF"
  GITLOG="$RUN_DIR/gitlog"; : > "$GITLOG"
  HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"; export HARNESS_EVENTS_FILE; : > "$HARNESS_EVENTS_FILE"
  LIVESTATE="$RUN_DIR/livestate"; echo CLOSED > "$LIVESTATE"   # what the stubbed live `gh issue view` answers
  export CALLS LIVE LIVESTATE
  command git init -q --bare -b main "$RUN_DIR/origin.git"
  command git clone -q "$RUN_DIR/origin.git" "$RUN_DIR/co" 2>/dev/null
  ( cd "$RUN_DIR/co" && echo hi > f && command git add f && command git commit -q -m init && command git branch -M main && command git push -q origin main )
  export HARNESS_CHECKOUT="$RUN_DIR/co"
  gh(){ echo "gh $*" >> "$CALLS"
        case "$1 $2" in
          "issue view") local n="$3" st; st="$(cat "$LIVESTATE")"
                        # #7 is always OPEN; #6 answers whatever the test set (CLOSED, OPEN, or EMPTY for a failed read)
                        [[ "$n" == 7 ]] && st=OPEN
                        [[ "$st" == EMPTY ]] && return 1
                        echo "{\"state\":\"$st\",\"labels\":[{\"name\":\"ready-for-agent\"}],\"title\":\"t$n\",\"body\":\"b\",\"comments\":[]}";; esac
        return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS"
          case "$1" in has-session) grep -qxF "$3" "$LIVE";; ls|list-sessions) cat "$LIVE";; esac; }
  export -f gh tmux
  git(){ case "$*" in *"worktree add"*) echo "$*" >> "$GITLOG";; esac; command git "$@"; }
  log(){ echo "$*" >> "$LOGF"; }
  render(){ echo "render $1" >> "$CALLS"; echo task; }
  launch_claude(){ echo "launch $1" >> "$CALLS"; echo "$1" >> "$LIVE"; }
  ensure_checkout(){ :; }; ensure_safe(){ :; }; win_repo_config(){ :; }; default_branch(){ echo main; }
  run_worktree_hook(){ :; }; resume_handoff(){ :; }; issue_parent_prd(){ :; }
  gh_rate_wait(){ :; }; ci_gate_ok(){ :; }; usage_watch(){ :; }; usage_held(){ return 1; }; gh_budget_low(){ return 1; }
  sleep(){ :; }; unit_complete(){ return 1; }
}
tick(){ local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx; prebuild_tick; }
WT(){ echo "$WORKTREES_DIR/main-i$1"; }
adds(){ grep -c "worktree add.*issue/$1 " "$GITLOG"; }
views(){ grep -c "gh issue view $1 " "$CALLS"; }
stamps(){ grep -c "gh issue edit $1 -R acme/widget --add-label agent-working" "$CALLS"; }
ev(){ grep -c "\"event\": *\"$1\"" "$HARNESS_EVENTS_FILE"; }

echo "=== 1. CLAIM GATE: snapshot OPEN, live CLOSED ==="
setup; snapshot 6
worker_tick W1; rc=$?
assert_eq "$(adds 6)" "0" "no worktree add for the closed #6"
assert_eq "$(stamps 6)" "0" "no agent-working stamp on the closed #6"
assert_no "no launch" grep -q '^launch' "$CALLS"
assert_eq "$(ev launch_failed)" "0" "no launch_failed event"
assert_eq "$(ev launch_skipped)" "1" "one launch_skipped event"
assert_ok "... reason=issue_closed" grep -Eq '"reason": *"issue_closed"' "$HARNESS_EVENTS_FILE"
assert_no "the claim is released" test -e "$CLAIMS_DIR/impl-6.claim"
assert_no "no launch backoff armed" test -e "$RUN_DIR/launchfail.impl-6"

echo "=== 2. NO RE-CLAIM: the next tick leaves #6 alone, takes #7 ==="
v=$(views 6)
worker_tick W1
assert_eq "$(views 6)" "$v" "no further gh issue view for #6 while the skip marker is active"
assert_eq "$(adds 6)" "0" "... and no worktree for it"
setup; snapshot 6 7
worker_tick W1; worker_tick W1
assert_eq "$(adds 7)" "1" "with #7 also ready, #7 is claimed (worktree added once)"
assert_ok "... and launched" grep -q 'launch hz-main-i7' "$CALLS"
assert_eq "$(adds 6)" "0" "... #6 never"
assert_eq "$(views 6)" "1" "#6 was read once, not on every tick"

echo "=== 3. PREBUILD: a ready worktree of the closed #6 is dropped, not kept ==="
setup; snapshot 5 6; echo hz-main-i5 > "$LIVE"
tick
assert_no "no ready worktree left for the closed #6" test -e "$(WT 6)/.git"
tick
assert_no "... and none after another tick" test -e "$(WT 6)/.git"
setup; snapshot 5 6; echo hz-main-i5 > "$LIVE"
echo OPEN > "$LIVESTATE"; tick; echo CLOSED > "$LIVESTATE"
assert_ok "(OPEN: #6 pre-built)" test -e "$(WT 6)/.git"
: > "$LIVE"; snapshot 6; worker_tick W1
assert_no "claiming the now-closed #6 drops the pre-built worktree" test -e "$(WT 6)"
assert_no "... and its marker" test -e "$(prebuilt_file main 6)"
assert_eq "$(ev prebuilt_dropped)" "1" "... with a prebuilt_dropped event"
assert_eq "$(stamps 6)" "0" "... and no agent-working stamp"

echo "=== 4. GOAL MET AT LAUNCH is not a failed launch ==="
setup; snapshot 7; fleet_ctx; mkdir -p "$CLAIMS_DIR"
NOW=5000; date(){ if [[ "${1:-}" == +%s ]]; then echo "$NOW"; else command date "$@"; fi; }
remove_worktree(){ :; }; unlock_issue(){ :; }; one_lease_live(){ return 1; }; is_claimed(){ [[ -f "$CLAIMS_DIR/$1.claim" ]]; }
SESS="$(sess_impl "$UNIT" 7)"
echo "$((NOW - 2)) uuid-7" > "$RUN_DIR/$SESS.launched"; echo "ISSUE:7" > "$RUN_DIR/$SESS.goal"; echo /tmp > "$RUN_DIR/$SESS.wd"
python3() { if [[ "${2:-}" == check ]]; then echo DONE; else command python3 "$@"; fi; }
cli_kill(){ :; }; stats_sess_event(){ :; }
session_live(){ return 1; }
check_session_goal "$SESS" live
reap_impl_lane 7
unset -f python3
assert_eq "$(ev launch_failed)" "0" "a lane reaped 2s after launch with a DONE goal check logs no launch_failed"
assert_no "... leaves no launchfail.impl-7 backoff" test -e "$RUN_DIR/launchfail.impl-7"
assert_ok "... and its goal-met mark is kept for the session_end" test -e "$RUN_DIR/$SESS.goalmet"
CTX="$RUN_DIR/$SESS.stats"; echo '{"session":"uuid-7","repo":"acme/widget","issue":7,"kind":"impl","goal":"ISSUE:7"}' > "$CTX"
churn_check(){ :; }; sess_sweep(){ :; }; _stats_cli_usage(){ :; }
stats_sweep_ended
assert_ok "... and its session_end carries goal_met" grep -Eq '"session_end".*"goal_met": *"?1|"goal_met": *"?1.*"session_end"' "$HARNESS_EVENTS_FILE"
assert_no "... the mark is consumed" test -e "$RUN_DIR/$SESS.goalmet"
# no DONE check -> still a failed launch
SESS8="$(sess_impl "$UNIT" 8)"; echo "$((NOW - 2)) uuid-8" > "$RUN_DIR/$SESS8.launched"
reap_impl_lane 8
assert_eq "$(ev launch_failed)" "1" "a young death WITHOUT a DONE goal check still logs launch_failed"
assert_ok "... and arms its backoff" launch_backoff_active impl-8

echo "=== 5. an OPEN issue is claimed and launched as before, with ONE gh issue view ==="
setup; snapshot 6; echo OPEN > "$LIVESTATE"
worker_tick W1
assert_ok "launched" grep -q 'launch hz-main-i6' "$CALLS"
assert_eq "$(views 6)" "1" "exactly one gh issue view in prepare_impl (#618)"
assert_eq "$(stamps 6)" "1" "agent-working stamped once"
assert_eq "$(ev launch_skipped)" "0" "no launch_skipped"

echo "=== 6. a failed live-state read does not block the claim ==="
setup; snapshot 6; echo EMPTY > "$LIVESTATE"
worker_tick W1
assert_ok "launched on a failed read" grep -q 'launch hz-main-i6' "$CALLS"
assert_eq "$(ev launch_skipped)" "0" "no launch_skipped"

echo "=== 7. #745: a skipped closed issue is not a failed spawn — claim again at once; a real failure still sleeps POLL ==="
setup; snapshot 6 7; POLL=300
step_stubs(){ snapshot_gate(){ return 0; }; roots_check(){ :; }; gc_orphan_goals(){ :; }; worker_chores(){ :; }; worker_tend(){ :; }; }
step_stubs
sleep(){ echo "sleep $1" >> "$CALLS"; }
worker_step W1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "7" "closed #6 skipped: worker_step rc 7 (not 6)"
assert_eq "$(grep -c '^sleep ' "$CALLS")" "0" "... no POLL sleep after the skip"
assert_no "... claim dropped" test -e "$CLAIMS_DIR/impl-6.claim"
worker_step W1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "the very next step claims the open #7"
assert_ok "... and launches it" grep -q 'launch hz-main-i7' "$CALLS"
assert_eq "$(grep -c '^sleep ' "$CALLS")" "0" "... still no sleep before the launch"
assert_eq "$(ev launch_failed)" "0" "no launch_failed event"
echo "-- a real spawn failure keeps the POLL sleep"
setup; snapshot 7; POLL=300; step_stubs
sleep(){ echo "sleep $1" >> "$CALLS"; }
spawn_impl(){ return 1; }
worker_step W1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "6" "failed spawn: rc 6"
assert_eq "$(grep -c '^sleep 300$' "$CALLS")" "1" "... sleeps POLL (#539)"

echo "=== 8. #593: a closed child keeps ready-for-agent (it is how the PRD counts its children); agent-working goes ==="
setup; fleet_ctx
: > "$CALLS"
closed_issue_unlabel 6 '{"state":"CLOSED","labels":[{"name":"ready-for-agent"},{"name":"agent-working"}]}'
assert_ok "agent-working is removed from the closed issue" grep -q -- "gh issue edit 6 -R acme/widget --remove-label agent-working" "$CALLS"
assert_no "ready-for-agent is NOT removed (the PRD would lose its only child and never be reviewed)" grep -q -- "--remove-label ready-for-agent" "$CALLS"
: > "$CALLS"
closed_issue_unlabel 6 '{"state":"CLOSED","labels":[{"name":"ready-for-agent"}]}'
assert_no "a closed issue with only ready-for-agent gets no gh issue edit at all" grep -q "gh issue edit" "$CALLS"

finish
