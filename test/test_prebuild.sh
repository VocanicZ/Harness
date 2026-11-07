#!/usr/bin/env bash
# test_prebuild.sh — #644: pre-build the next claimable issue's worktree while the current lane runs.
# A lane switch paid `git worktree add`, the worktree hook and the ensure_* setup (about 10 s of 10-15) once the issue was
# claimed. prebuild_tick (drive.sh, called by worker_chores) builds that worktree while another lane runs; prepare_impl reuses it.
#   1. a lane runs (#5), #6 is claimable: #6's worktree is built, marked, and #6 gets NO agent-working label.
#   2. REUSE: the lane ends, a worker_tick claims #6: no second `worktree add`, no second hook run; agent-working goes on only
#      now; the marker is gone; the task file is rendered into the pre-built worktree.
#   3. REAP PROTECTION: reap_team leaves the pre-built worktree alone while #6 is claimable (and takes it without the marker).
#   4. CLEANUP: #6 claimed elsewhere (agent-working), closed, or blocked -> worktree, local branch and marker are removed.
#      A claim that landed first keeps the worktree. A dead builder's marker is swept. HARNESS_PREBUILD=0 builds nothing.
# Real git (a bare origin + a clone) and the real issuelib.py over a snapshot; gh, tmux and the launch are stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"; source "$HERE/helpers.sh"

# snapshot <spec>... — the poller's view of the board; a spec is `N|labels,csv|STATE|body` (body: \n = newline).
snapshot(){ python3 - "$SNAP" "$@" <<'EOF'
import json, sys, time
path, specs = sys.argv[1], sys.argv[2:]
issues = []
for sp in specs:
    n, labels, state, body = (sp.split("|", 3) + ["", "", "", ""])[:4]
    issues.append({"number": int(n), "title": f"t{n}", "state": state or "OPEN", "body": body.replace("\\n", "\n"),
                   "labels": [{"name": l} for l in labels.split(",") if l],
                   "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"})
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget",
           "issues": issues, "has_plan": False, "plan_marker": None, "self_login": "bot",
           "ext_deps": {}, "issue_branches": []}, open(path, "w"))
EOF
}

setup(){
  make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; POOL=2; POLL=0
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  HARNESS_PREBUILD=1; unset HARNESS_WORKTREE_HOOK
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LIVE="$RUN_DIR/live"; : > "$LIVE"; LOGF="$RUN_DIR/log"; : > "$LOGF"
  GITLOG="$RUN_DIR/gitlog"; : > "$GITLOG"; HOOKLOG="$RUN_DIR/hooklog"; : > "$HOOKLOG"
  export CALLS LIVE
  # the fleet's clone, with a real origin to cut worktrees from
  command git init -q --bare -b main "$RUN_DIR/origin.git"
  command git clone -q "$RUN_DIR/origin.git" "$RUN_DIR/co" 2>/dev/null
  ( cd "$RUN_DIR/co" && echo hi > f && command git add f && command git commit -q -m init && command git branch -M main && command git push -q origin main )
  export HARNESS_CHECKOUT="$RUN_DIR/co"
  gh(){ echo "gh $*" >> "$CALLS"; case "$1 $2" in "issue view") echo '[]';; esac; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS"
          case "$1" in has-session) grep -qxF "$3" "$LIVE";; ls|list-sessions) cat "$LIVE";; esac; }
  export -f gh tmux
  git(){ case "$*" in *"worktree add"*) echo "$*" >> "$GITLOG";; esac; command git "$@"; }
  log(){ echo "$*" >> "$LOGF"; }
  render(){ echo "render $1" >> "$CALLS"; echo task; }
  launch_claude(){ echo "launch $1" >> "$CALLS"; echo "$1" >> "$LIVE"; }
  ensure_checkout(){ :; }; ensure_safe(){ :; }; win_repo_config(){ :; }; default_branch(){ echo main; }
  run_worktree_hook(){ echo "hook $1" >> "$HOOKLOG"; }
  resume_handoff(){ :; }; issue_parent_prd(){ :; }; harness_event(){ :; }; stats_sweep_ended(){ :; }
  gh_rate_wait(){ :; }; ci_gate_ok(){ :; }; usage_watch(){ :; }; usage_held(){ return 1; }; gh_budget_low(){ return 1; }
  sleep(){ :; }
  unit_complete(){ return 1; }
}
tick(){ local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx; prebuild_tick; }
sweep(){ local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx; prebuild_sweep; }
reap(){ local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx; reap_team; }
WT(){ echo "$WORKTREES_DIR/main-i$1"; }
adds(){ grep -c "worktree add.*issue/$1 " "$GITLOG"; }
add_label_on(){ grep -c "gh issue edit $1 -R acme/widget --add-label agent-working" "$CALLS"; }
branch_exists(){ command git -C "$RUN_DIR/co" show-ref --verify --quiet "refs/heads/issue/$1"; }
# a lane is running on #5; #6 is ready and claimable
lane_running(){ snapshot "5|ready-for-agent,agent-working|OPEN" "6|ready-for-agent|OPEN"; echo hz-main-i5 > "$LIVE"; }

echo "=== a lane runs on #5, #6 is claimable: #6's worktree is built ahead, unlabelled ==="
setup; lane_running
tick
assert_ok "#6 has a worktree" test -e "$(WT 6)/.git"
assert_eq "$(command git -C "$(WT 6)" symbolic-ref --short HEAD)" "issue/6" "... on issue/6"
assert_eq "$(prebuilt_state main 6)" "ready" "... marked ready"
assert_eq "$(adds 6)" "1" "... by one worktree add"
assert_eq "$(wc -l < "$HOOKLOG" | tr -d ' ')" "1" "... and one worktree hook run"
assert_eq "$(add_label_on 6)" "0" "#6 is NOT labelled agent-working when its worktree is pre-built (#416)"
assert_no "no gh issue edit at all" grep -q 'gh issue edit' "$CALLS"
assert_eq "$(busy_issues_for main)" "5" "a ready pre-built worktree does not make #6 busy: it stays claimable"
tick
assert_eq "$(adds 6)" "1" "a second tick builds nothing more"

echo "=== REUSE: the lane ends and #6 is claimed: no second add, no second hook, label only now ==="
: > "$LIVE"; snapshot "5|ready-for-agent,agent-working|OPEN" "6|ready-for-agent|OPEN"
POOL=1; worker_tick W1
assert_eq "$?" "0" "the claim and spawn succeeded"
assert_eq "$(adds 6)" "1" "spawning #6 ran no worktree add"
assert_eq "$(wc -l < "$HOOKLOG" | tr -d ' ')" "1" "... and no second worktree hook"
assert_eq "$(add_label_on 6)" "1" "agent-working is stamped once, when the lane starts"
assert_ok "#6 launched" grep -q 'launch hz-main-i6' "$CALLS"
assert_no "the marker is consumed" test -e "$(prebuilt_file main 6)"
assert_eq "$(cat "$(WT 6)/.harness-task.md")" "task" "the task file is rendered into the pre-built worktree"
assert_eq "$(command git -C "$(WT 6)" symbolic-ref --short HEAD)" "issue/6" "the lane is on issue/6"

echo "=== REUSE moves the branch to today's origin/main ==="
setup; lane_running; tick
( cd "$RUN_DIR/co" && echo more > g && command git add g && command git commit -q -m next && command git push -q origin main )
tip="$(command git -C "$RUN_DIR/co" rev-parse HEAD)"
: > "$LIVE"; POOL=1; worker_tick W1
assert_eq "$(command git -C "$(WT 6)" rev-parse HEAD)" "$tip" "the reused worktree is at the new origin/main"

echo "=== REAP PROTECTION: reap_team keeps a pre-built worktree while #6 is claimable ==="
setup; lane_running; tick
reap
assert_ok "worktree survives reap_team" test -e "$(WT 6)/.git"
assert_ok "marker survives" test -e "$(prebuilt_file main 6)"
rm -f "$(prebuilt_file main 6)"
HARNESS_LAUNCH_FAIL_SECS=0   # past the #643 launch grace a seconds-old, sessionless worktree is a leftover
reap
assert_no "without the marker the same worktree is a leftover and is reaped" test -e "$(WT 6)"

echo "=== CLEANUP: #6 claimed elsewhere (agent-working) ==="
setup; lane_running; tick
snapshot "5|ready-for-agent,agent-working|OPEN" "6|ready-for-agent,agent-working|OPEN"
tick
assert_no "worktree removed" test -e "$(WT 6)"
assert_no "marker removed" test -e "$(prebuilt_file main 6)"
assert_no "local branch removed" branch_exists 6
assert_no "... and not rebuilt next tick" test -e "$(WT 6)"

echo "=== CLEANUP: #6 closed ==="
setup; lane_running; tick
snapshot "5|ready-for-agent,agent-working|OPEN" "6|ready-for-agent|CLOSED"
tick
assert_no "worktree removed" test -e "$(WT 6)"
assert_no "marker removed" test -e "$(prebuilt_file main 6)"

echo "=== CLEANUP: #6 blocked by an open #9 ==="
setup; lane_running; tick
snapshot "5|ready-for-agent,agent-working|OPEN" "6|ready-for-agent|OPEN|## Blocked by\n- #9" "9|ready-for-agent,agent-working|OPEN"
tick
assert_no "worktree removed" test -e "$(WT 6)"
assert_no "marker removed" test -e "$(prebuilt_file main 6)"
assert_no "local branch removed" branch_exists 6

echo "=== CLEANUP: a claim that landed first keeps the worktree ==="
setup; lane_running; tick
snapshot "5|ready-for-agent,agent-working|OPEN" "6|ready-for-agent,agent-working|OPEN"
lane_claim_write impl-6 W9 IMPL:6 hz-main-i6
tick
assert_ok "claimed #6: worktree stays for its lane" test -e "$(WT 6)/.git"
rm -f "$CLAIMS_DIR/impl-6.claim"

echo "=== CLEANUP: a builder that died mid-add leaves a marker the sweep clears ==="
setup; lane_running
mkdir -p "$RUN_DIR/prebuilt"; printf 'building 1 999999\n' > "$(prebuilt_file main 6)"
command git -C "$RUN_DIR/co" worktree add -q -B issue/6 "$(WT 6)" origin/main
assert_no "a dead builder's marker is not 'building'" prebuilt_building main 6
sweep
assert_no "stale worktree removed" test -e "$(WT 6)"
assert_no "stale marker removed" test -e "$(prebuilt_file main 6)"

echo "=== a marker whose worktree vanished is dropped, not kept ==="
setup; lane_running; tick
rm -rf "$(WT 6)"; command git -C "$RUN_DIR/co" worktree prune
sweep
assert_no "marker gone with its worktree" test -e "$(prebuilt_file main 6)"

echo "=== nothing runs, nothing is pre-built; HARNESS_PREBUILD=0 builds nothing ==="
setup; snapshot "6|ready-for-agent|OPEN"; : > "$LIVE"
tick
assert_no "no lane running: no pre-build" test -e "$(WT 6)"
setup; lane_running; HARNESS_PREBUILD=0
tick
assert_no "HARNESS_PREBUILD=0: no pre-build" test -e "$(WT 6)"

echo "=== a paused fleet builds nothing ==="
setup; lane_running; touch "$PAUSE_FLAG"
tick
assert_no "paused: no pre-build" test -e "$(WT 6)"

echo "=== a failed add is not retried every tick ==="
setup; lane_running
git(){ case "$*" in *"worktree add"*) echo "$*" >> "$GITLOG"; return 128;; esac; command git "$@"; }
tick; tick
assert_eq "$(grep -c 'worktree add.*issue/6 .*origin/main' "$GITLOG")" "1" "one attempt, then the failure stamp holds the retry"
assert_no "no marker left" test -e "$(prebuilt_file main 6)"

echo "=== an issue whose lane just failed to launch (backoff) is not pre-built ==="
setup; lane_running
launch_backoff_active(){ true; }
backoff_keys(){ [[ "$1" == impl ]] && echo 6; }
tick
assert_no "backed-off #6: no pre-build" test -e "$(WT 6)"

finish
