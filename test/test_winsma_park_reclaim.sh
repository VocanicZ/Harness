#!/usr/bin/env bash
# test_winsma_park_reclaim.sh — #1092: a lane parked in the winsma lock queue (winsma.sh park, #1034) must not be claimed again
# from the host snapshot, which lags the park (it still shows the issue without waiting-winsma and without agent-working).
# Modelled on test_closed_reclaim.sh (#730), the closed-issue twin of the same snapshot lag.
#   1. CLAIM GATE: snapshot says #6 is claimable, live `gh issue view 6` carries waiting-winsma -> worker_tick launches nothing,
#      adds no worktree, stamps no agent-working, logs no launch_failed, arms no backoff, drops the claim; launch_skipped
#      reason=winsma_parked.
#   2. NO CHURN: later ticks claim no #6 and read no more; another claimable #7 is still taken (no slot lost, no POLL sleep).
#   3. LOCAL SPEC: a resume=redispatch winsma spec under $RUN_DIR keeps #6 out of claim_lane before any gh call.
#   4. STALE SPEC: a spec older than the snapshot (or past the ageout) does not block for ever.
#   5. PREBUILD: no worktree is built for a live-parked #6; a pre-built one is dropped (prebuilt_dropped).
#   6. WAKE: after winsma_wake_tick removes the label, #6 is claimed as a resume even on a snapshot that still lacks the label.
#   7. PRD REVIEW PARK: a PRD with the live label (snapshot without) gets no REVIEW session and no orch worktree.
#   8. UNCHANGED: an un-parked issue makes exactly ONE gh issue view (#618); a failed live read does not block the claim (#730).
# Real git (a bare origin + a clone) and the real issuelib.py over a snapshot; gh, tmux and the launch are stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"; source "$HERE/helpers.sh"

# snapshot <issue>... — each issue OPEN + ready-for-agent (no waiting label: a pre-park snapshot). SNAPGEN = generated_at offset (s).
snapshot(){ python3 - "$SNAP" "${SNAPGEN:-0}" "$@" <<'EOF2'
import json, sys, time
path, off, nums = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
issues = [{"number": int(n), "title": f"t{n}", "state": "OPEN", "body": "## What to build\nx\n",
           "labels": [{"name": "ready-for-agent"}], "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"} for n in nums]
json.dump({"schema_version": 1, "generated_at": time.time() + off, "slug": "acme/widget", "issues": issues, "has_plan": False,
           "plan_marker": None, "self_login": "bot", "ext_deps": {}, "issue_branches": []}, open(path, "w"))
EOF2
}
# snapshot_prd — PRD #9 (labelled prd) with ONE closed ready child #10, no waiting label: REVIEW is due.
snapshot_prd(){ python3 - "$SNAP" "${SNAPGEN:-0}" <<'EOF2'
import json, sys, time
path, off = sys.argv[1], float(sys.argv[2])
mk = lambda n, st, labels, body: {"number": n, "title": f"t{n}", "state": st, "body": body, "labels": [{"name": l} for l in labels],
                                  "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"}
issues = [mk(9, "OPEN", ["prd"], "## Problem\nx\n"), mk(10, "CLOSED", ["ready-for-agent"], "## Parent\n#9\n")]
json.dump({"schema_version": 1, "generated_at": time.time() + off, "slug": "acme/widget", "issues": issues, "has_plan": False,
           "plan_marker": None, "self_login": "bot", "ext_deps": {}, "issue_branches": []}, open(path, "w"))
EOF2
}

setup(){
  make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; POOL=2; POLL=0
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude HARNESS_CI_GATE=0
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  HARNESS_PREBUILD=1; unset HARNESS_WORKTREE_HOOK HARNESS_WAIT_FILE; unset SNAPGEN
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LIVE="$RUN_DIR/live"; : > "$LIVE"; LOGF="$RUN_DIR/log"; : > "$LOGF"
  GITLOG="$RUN_DIR/gitlog"; : > "$GITLOG"
  HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"; export HARNESS_EVENTS_FILE; : > "$HARNESS_EVENTS_FILE"
  LIVELABELS="$RUN_DIR/livelabels"; echo "ready-for-agent waiting-winsma" > "$LIVELABELS"   # what the stubbed live `gh issue view` answers for #6 and #9
  export CALLS LIVE LIVELABELS
  command git init -q --bare -b main "$RUN_DIR/origin.git"
  command git clone -q "$RUN_DIR/origin.git" "$RUN_DIR/co" 2>/dev/null
  ( cd "$RUN_DIR/co" && echo hi > f && command git add f && command git commit -q -m init && command git branch -M main && command git push -q origin main )
  export HARNESS_CHECKOUT="$RUN_DIR/co"
  gh(){ echo "gh $*" >> "$CALLS"
        case "$1 $2" in
          "issue view") local n="$3" labels json="" l
                        [[ "$n" == 7 ]] && labels="ready-for-agent" || labels="$(cat "$LIVELABELS")"
                        [[ "$labels" == EMPTY ]] && return 1
                        case "$*" in *" -q "*) tr ' ' '\n' <<<"$labels"; return 0;; esac   # the wake tick asks for bare label names
                        for l in $labels; do json+="${json:+,}{\"name\":\"$l\"}"; done
                        echo "{\"state\":\"OPEN\",\"labels\":[$json],\"title\":\"t$n\",\"body\":\"b\",\"comments\":[]}";;
          "issue edit") case "$*" in *"--remove-label waiting-winsma"*) sed -i 's/ *waiting-winsma//' "$LIVELABELS";; esac;;
        esac
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
claim(){ local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx; claim_lane W1; }
WT(){ echo "$WORKTREES_DIR/main-i$1"; }
adds(){ grep -c "worktree add.*issue/$1 " "$GITLOG"; }
views(){ grep -c "gh issue view $1 " "$CALLS"; }
stamps(){ grep -c "gh issue edit $1 -R acme/widget --add-label agent-working" "$CALLS"; }
ev(){ grep -c "\"event\": *\"$1\"" "$HARNESS_EVENTS_FILE"; }
# park_spec <issue> [created-offset] — what `winsma.sh park` writes: a resume=redispatch winsma wait spec in the lane's wait file.
park_spec(){ HARNESS_WAIT_FILE="$RUN_DIR/hz-main-i$1.wait" python3 "$WAITLIB_PY" set --winsma "$1" --deadline-s 3600 --resume redispatch >/dev/null 2>&1; }

echo "=== 1. CLAIM GATE: snapshot claimable, live waiting-winsma ==="
setup; snapshot 6
worker_tick W1; rc=$?
assert_eq "$rc" "7" "worker_tick: skipped, not failed (rc 7, as #745)"
assert_eq "$(adds 6)" "0" "no worktree add for the parked #6"
assert_eq "$(stamps 6)" "0" "no agent-working stamp on the parked #6"
assert_no "no launch" grep -q '^launch' "$CALLS"
assert_eq "$(ev launch_failed)" "0" "no launch_failed event"
assert_eq "$(ev launch_skipped)" "1" "one launch_skipped event"
assert_ok "... reason=winsma_parked" grep -Eq '"reason": *"winsma_parked"' "$HARNESS_EVENTS_FILE"
assert_no "the claim is released" test -e "$CLAIMS_DIR/impl-6.claim"
assert_no "no launch backoff armed" test -e "$RUN_DIR/launchfail.impl-6"
assert_no "no agent-working / label edit at all on the parked issue" grep -q "gh issue edit 6" "$CALLS"

echo "=== 2. NO CHURN: the next ticks leave #6 alone and still take #7 ==="
v=$(views 6)
worker_tick W1; worker_tick W1
assert_eq "$(views 6)" "$v" "no further gh issue view for #6 while the mark is active"
assert_eq "$(adds 6)" "0" "... and no worktree for it"
setup; snapshot 6 7
worker_tick W1; worker_tick W1; worker_tick W1
assert_eq "$(adds 7)" "1" "with #7 also ready, #7 is claimed (worktree added once)"
assert_ok "... and launched" grep -q 'launch hz-main-i7' "$CALLS"
assert_eq "$(adds 6)" "0" "... #6 never"
assert_eq "$(views 6)" "1" "#6 was read once, not on every tick"

echo "=== 3. LOCAL SPEC: a redispatch spec keeps #6 out of claim_lane before any gh call ==="
setup; snapshot 6; park_spec 6
assert_ok "(the spec is there)" test -s "$RUN_DIR/hz-main-i6.wait"
out="$(claim)"
assert_eq "$out" "" "claim_lane claims nothing"
assert_eq "$(views 6)" "0" "... and makes no gh issue view 6"
assert_no "... and writes no claim" test -e "$CLAIMS_DIR/impl-6.claim"
setup; snapshot 6 7; park_spec 6
out="$(claim)"
assert_eq "$(cut -f1,2 <<<"$out")" "$(printf 'IMPL\t7')" "with #7 ready too, the claim is #7"

echo "=== 4. STALE SPEC: a spec older than the snapshot, or past the ageout, does not block for ever ==="
setup; park_spec 6; SNAPGEN=30 snapshot 6; echo "ready-for-agent" > "$LIVELABELS"   # a human removed the label; the snapshot is newer than the spec
out="$(claim)"
assert_eq "$(cut -f1,2 <<<"$out")" "$(printf 'IMPL\t6')" "a spec older than the snapshot's generated_at: #6 is claimed"
setup; snapshot 6; park_spec 6; echo "ready-for-agent" > "$LIVELABELS"
out="$(HARNESS_PARKED_LIVE_SECS=0 claim)"
assert_eq "$(cut -f1,2 <<<"$out")" "$(printf 'IMPL\t6')" "a spec past the ageout: #6 is claimed"
setup; snapshot 6; echo "ready-for-agent" > "$LIVELABELS"; worker_tick W1
assert_ok "an un-parked #6 (no spec, no label) is launched" grep -q 'launch hz-main-i6' "$CALLS"

echo "=== 5. PREBUILD: no worktree for a live-parked #6; a pre-built one is dropped ==="
setup; snapshot 5 6; echo hz-main-i5 > "$LIVE"
tick
assert_no "no worktree built for the parked #6" test -e "$(WT 6)/.git"
tick
assert_no "... nor after another tick" test -e "$(WT 6)/.git"
assert_eq "$(adds 6)" "0" "... no worktree add at all"
setup; snapshot 5 6; echo hz-main-i5 > "$LIVE"
echo "ready-for-agent" > "$LIVELABELS"; tick
assert_ok "(un-parked: #6 pre-built)" test -e "$(WT 6)/.git"
echo "ready-for-agent waiting-winsma" > "$LIVELABELS"; : > "$LIVE"; snapshot 6; worker_tick W1
assert_no "claiming the now-parked #6 drops the pre-built worktree" test -e "$(WT 6)"
assert_no "... and its marker" test -e "$(prebuilt_file main 6)"
assert_eq "$(ev prebuilt_dropped)" "1" "... with a prebuilt_dropped event"
assert_eq "$(stamps 6)" "0" "... and no agent-working stamp"

echo "=== 6. WAKE: after winsma_wake_tick removes the label, #6 is claimed as a resume ==="
setup; snapshot 6
worker_tick W1                                                     # live-parked: marked, skipped
assert_ok "(marked parked)" test -e "$(parked_live_file 6)"
park_spec 6
python3 - "$SNAP" <<'EOF2'
import json, sys
d = json.load(open(sys.argv[1]))
for i in d["issues"]: i["labels"].append({"name": "waiting-winsma"})
json.dump(d, open(sys.argv[1], "w"))
EOF2
( fleet_ctx; HARNESS_WINDOWS_HOST="" winsma_wake_tick )                       # the snapshot has caught up with the park; the host is free
assert_ok "the wake tick removed the label" grep -q 'gh issue edit 6 .*--remove-label waiting-winsma' "$CALLS"
assert_no "... forgot the spec" test -e "$RUN_DIR/hz-main-i6.wait"
assert_no "... and cleared the parked mark" test -e "$(parked_live_file 6)"
snapshot 6                                                         # the snapshot lags the other way: no label
: > "$CALLS"; worker_tick W1
assert_ok "#6 is launched on the next tick" grep -q 'launch hz-main-i6' "$CALLS"
assert_eq "$(stamps 6)" "1" "... after its agent-working stamp"

echo "=== 7. PRD REVIEW PARK: a live-parked PRD gets no REVIEW session and no orch worktree ==="
setup; snapshot_prd
HARNESS_MODE=prd
worker_tick W1; rc=$?
assert_no "no session for the parked PRD review" grep -q '^launch' "$CALLS"
assert_eq "$(grep -c 'worktree add.*orch-9' "$GITLOG")" "0" "no orch worktree"
assert_no "no claim left" test -e "$CLAIMS_DIR/orch-9.claim"
assert_eq "$(ev launch_failed)" "0" "no launch_failed event"
assert_ok "launch_skipped reason=winsma_parked" grep -Eq '"reason": *"winsma_parked"' "$HARNESS_EVENTS_FILE"
v=$(views 9); worker_tick W1
assert_eq "$(views 9)" "$v" "the next tick does not read the PRD again"
setup; HARNESS_MODE=prd; snapshot_prd; echo "prd" > "$LIVELABELS"; worker_tick W1
assert_ok "(control) an un-parked PRD gets its REVIEW" grep -q '^launch hz-main-p9' "$CALLS"

echo "=== 8. UNCHANGED: ONE gh issue view for an un-parked issue; a failed live read does not block ==="
setup; snapshot 6; echo "ready-for-agent" > "$LIVELABELS"
worker_tick W1
assert_ok "launched" grep -q 'launch hz-main-i6' "$CALLS"
assert_eq "$(views 6)" "1" "exactly one gh issue view in prepare_impl (#618)"
assert_eq "$(ev launch_skipped)" "0" "no launch_skipped"
setup; snapshot 6; echo EMPTY > "$LIVELABELS"
worker_tick W1
assert_ok "launched on a failed read" grep -q 'launch hz-main-i6' "$CALLS"
assert_eq "$(ev launch_skipped)" "0" "no launch_skipped"

finish
