#!/usr/bin/env bash
# test_busy_issues.sh — #416: dispatch decided an issue was claimable from its LABELS alone. A live
# lane that dropped agent-working (it checkpointed, or self-parked agent-paused) left the issue
# {ready-for-agent, agent-paused}, so every pool pass re-claimed it: prepare_impl stamped
# agent-working, `worktree add` failed on the lane's own worktree, the label flapped, and the
# resumable-first order (#210) handed the stuck issue the only free slot.
#   1. live lane on #5 (session + worktree), #5 {ready, agent-paused}: no IMPL 5, no add-label on 5,
#      no `worktree add failed #5`.
#   2. same + a second claimable #6, one free slot: IMPL 6.
#   3. a worktree left without its session still owns the issue (its reaper does); the session alone too.
#   4. a dead lane (no session, no worktree) on #5 {ready, agent-paused}: IMPL 5, resume.md rendered.
# One real drive_unit tick over a snapshot with the real issuelib.py; gh, tmux, git worktree add and
# the launch are stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"

# snapshot <#5 labels csv> [<#6 labels csv>] — the poller's view of the board.
snapshot(){ python3 - "$SNAP" "$1" "${2:-}" <<'EOF'
import json, sys, time
path, l5, l6 = sys.argv[1:]
def issue(n, labels):
    return {"number": n, "title": f"t{n}", "state": "OPEN", "body": "",
            "labels": [{"name": l} for l in labels.split(",") if l],
            "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"}
issues = [issue(5, l5)] + ([issue(6, l6)] if l6 else [])
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget",
           "issues": issues, "has_plan": False, "plan_marker": None, "self_login": "bot",
           "ext_deps": {}, "issue_branches": []}, open(path, "w"))
EOF
}

setup(){
  make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; POOL=2; POLL=0
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LIVE="$RUN_DIR/live"; : > "$LIVE"; LOGF="$RUN_DIR/log"; : > "$LOGF"
  export CALLS LIVE
  gh(){ echo "gh $*" >> "$CALLS"
        case "$1 $2" in "issue view") echo '[]';; esac; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS"
          case "$1" in
            has-session) grep -qxF "$3" "$LIVE";;
            ls|list-sessions) cat "$LIVE";;
          esac; }
  export -f gh tmux
  # `worktree add` fails exactly like git does when the lane's worktree already holds issue/<n>.
  git(){ case "$*" in
           *"worktree add"*) local wd; for wd in "$@"; do [[ "$wd" == "$WORKTREES_DIR"/* ]] && break; done
                             [[ -d "$wd" ]] && return 128; echo "git $*" >> "$CALLS"; mkdir -p "$wd"; return 0;;
         esac; return 0; }
  log(){ echo "$*" >> "$LOGF"; }
  render(){ echo "render $1" >> "$CALLS"; }
  launch_claude(){ echo "launch $1" >> "$CALLS"; echo "$1" >> "$LIVE"; }
  ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }; default_branch(){ echo main; }
  resume_handoff(){ :; }; issue_parent_prd(){ :; }; harness_event(){ :; }; stats_sweep_ended(){ :; }
  reap_done_sessions(){ :; }; reap_team(){ :; }; reap_orch(){ :; }; watchdog_team(){ :; }
  one_auto_tend(){ :; }; reap_finished_inject(){ :; }; reap_pool_bugs(){ :; }; release_tick(){ :; }
  retry_pending_unlocks(){ :; }; sweep_orphan_locks(){ :; }; finalize_unit(){ :; }
  gh_rate_wait(){ :; }; ci_gate_ok(){ :; }; usage_watch(){ :; }; usage_held(){ return 1; }; gh_budget_low(){ return 1; }
  sleep(){ :; }
  TICKS="$RUN_DIR/ticks"; echo 0 > "$TICKS"
  unit_complete(){ local n; n=$(( $(cat "$TICKS") + 1 )); echo "$n" > "$TICKS"; (( n > 1 )); }   # one tick
}
add_label_on(){ grep -c "gh issue edit $1 -R acme/widget --add-label agent-working" "$CALLS"; }

echo "=== a live lane still owns #5 (session + worktree), #5 is {ready, agent-paused}: never re-claimed ==="
setup
snapshot "ready-for-agent,agent-paused"
echo hz-main-i5 > "$LIVE"; mkdir -p "$WORKTREES_DIR/main-i5"
drive_unit main
assert_eq "$(add_label_on 5)" "0" "no --add-label agent-working on #5"
assert_no "no 'worktree add failed #5' logged" grep -q 'worktree add failed #5' "$LOGF"
assert_no "no launch for #5" grep -q 'launch hz-main-i5' "$CALLS"
assert_eq "$(busy_issues_for main)" "5" "busy_issues_for names #5"

echo "=== the same + a second claimable #6, one free slot: the slot goes to #6 ==="
setup
snapshot "ready-for-agent,agent-paused" "ready-for-agent"
echo hz-main-i5 > "$LIVE"; mkdir -p "$WORKTREES_DIR/main-i5"
drive_unit main
assert_eq "$(add_label_on 5)" "0" "no --add-label agent-working on #5"
assert_eq "$(add_label_on 6)" "1" "#6 claimed exactly once"
assert_ok "#6 launched" grep -q 'launch hz-main-i6' "$CALLS"

echo "=== a worktree without its session, or a session without its worktree, still owns the issue ==="
setup
mkdir -p "$WORKTREES_DIR/main-i5" "$WORKTREES_DIR/bug-acme_widget-i8" "$WORKTREES_DIR/triage-acme_widget-i9"
printf '%s\n' hz-main-i7 hz-bug-acme_widget-11-fix hz-main-p41 hz-other-i12 > "$LIVE"
mkdir -p "$WORKTREES_DIR/other-i13"
assert_eq "$(busy_issues_for main)" "5,7,8,9,11" "worktrees (impl/bug/triage) + live impl/bug sessions; not orch PRDs, not other units"
mkdir -p "$RUN_DIR/one"; printf 'main\tacme/widget\t14\n' > "$(one_lease_file main 14)"
assert_eq "$(busy_issues_for main)" "5,7,8,9,11,14" "a fresh /harness-one lease owns its issue"
: > "$LIVE"; rm -rf "${WORKTREES_DIR:?}"/* "$RUN_DIR/one"
assert_eq "$(busy_issues_for main)" "" "nothing live: empty"
# the backstop past dispatch: a direct IMPL for an owned issue fails at `worktree add`, before any claim
mkdir -p "$WORKTREES_DIR/main-i5"; : > "$CALLS"
UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; CHECKOUT="$RUN_DIR/co"
spawn_impl 5 "ISSUE 5 DONE"; assert_eq "$?" "1" "spawn_impl fails for an issue whose worktree still exists"
assert_eq "$(add_label_on 5)" "0" "... without stamping agent-working"
assert_no "... and launches nothing" grep -q 'launch hz-main-i5' "$CALLS"

echo "=== a dead lane (no session, no worktree) on #5 {ready, agent-paused}: dispatched, resume.md ==="
setup
snapshot "ready-for-agent,agent-paused" "ready-for-agent"
POOL=1
gh(){ echo "gh $*" >> "$CALLS"
      case "$1 $2" in "issue view") echo '["ready-for-agent","agent-paused"]';; esac; return 0; }
drive_unit main
assert_eq "$(add_label_on 5)" "1" "#5 re-claimed (resumable first, #210)"
assert_ok "#5 launched" grep -q 'launch hz-main-i5' "$CALLS"
assert_ok "#5 renders resume.md" grep -q 'render .*prompts/resume.md' "$CALLS"
assert_eq "$(add_label_on 6)" "0" "the one slot went to #5, not #6"

finish
