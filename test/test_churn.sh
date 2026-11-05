#!/usr/bin/env bash
# test_churn.sh — #545: the crash-loop guard on the reap path.
#   A fake fleet whose every launched session dies young: stats_sweep_ended (the call every reaper makes
#   before it unlocks an issue) trips the guard on the third. The issue loses agent-working, gains
#   agent-blocked, gets the evidence comment, THEN the park record (so its own edits do not lift the
#   park), a `churn` event, and no claim path hands it out again. Fake gh, temporary events / park / run
#   dirs; the tmux seam is a function, so the live server is never reached.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"

setup(){
  make_env
  HARNESS_REPO="acme/widget"; HARNESS_SESS_PREFIX=hz; UNIT=main; SLUG="acme/widget"; REPO="acme/widget"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0
  export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl" HARNESS_PARKED_FILE="$RUN_DIR/parked"
  export HARNESS_CLAUDE_CONFIG_DIRS="$RUN_DIR/cfg" HARNESS_HEADLESS_DIR="$RUN_DIR/lanes"
  unset HARNESS_BLOCKED_BACKOFF_MIN HARNESS_CHURN_COUNT HARNESS_CHURN_MAX_WALL_S HARNESS_CHURN_WINDOW_MIN
  STATS_PY="$HERE/../scripts/stats.py"; CHURN_PY="$HERE/../scripts/churn.py"
  mkdir -p "$RUN_DIR/cfg"
  : > "$HARNESS_EVENTS_FILE"
  GHLOG="$RUN_DIR/gh.log"; : > "$GHLOG"
  LABELS="$RUN_DIR/labels"; echo "agent-working" > "$LABELS"   # the issue's labels, one per line
  STATE="$RUN_DIR/istate"; echo OPEN > "$STATE"
  UPD="$RUN_DIR/upd"; echo 100 > "$UPD"                        # GitHub's updatedAt: any edit or comment bumps it
  gh(){ echo "gh $*" >> "$GHLOG"
    case "$1 $2" in
      "issue edit") local a; while (($#)); do case "$1" in
            --remove-label) grep -vxF "$2" "$LABELS" > "$LABELS.n"; mv "$LABELS.n" "$LABELS"; shift;;
            --add-label) grep -qxF "$2" "$LABELS" || echo "$2" >> "$LABELS"; shift;; esac; shift; done
          echo $(( $(cat "$UPD") + 1 )) > "$UPD";;
      "issue comment") echo $(( $(cat "$UPD") + 1 )) > "$UPD"
          while (($#)); do [[ "$1" == --body ]] && { printf '%s' "$2" > "$RUN_DIR/comment.$(( $(cat "$UPD") ))"; echo "$(cat "$UPD")" > "$RUN_DIR/last-comment"; }; shift; done;;
      "issue view")
          if [[ "$*" == *comments* ]]; then cat "$RUN_DIR/churn-comment" 2>/dev/null
          elif [[ "$*" == *updatedAt* ]]; then date -u -d "@$(( 1800000000 + $(cat "$UPD") ))" +%Y-%m-%dT%H:%M:%SZ
          else printf '{"state":"%s","labels":[%s]}\n' "$(cat "$STATE")" \
                 "$(sed 's/.*/{"name":"&"}/' "$LABELS" | paste -sd, -)"; fi;;
      "api user") echo bot;;
    esac; return 0; }
  LIVE="$RUN_DIR/live"; : > "$LIVE"
  tmux(){ case "$1" in has-session) grep -qxF "$3" "$LIVE";; ls|list-sessions) cat "$LIVE";; esac; }
  sess_sweep(){ :; }
  remove_worktree(){ rm -rf "$2"; }
}

# end_session <n> <kind> <unit> <wall_s> — a session that ran wall_s seconds and is now gone: its .stats
# context is left in RUN_DIR, as a real one is, and its transcript's last call is a SIGKILLed suite.
NOW0=$(date +%s)
end_session(){ local n="$1" kind="$2" unit="$3" wall="$4" sess uuid
  uuid="u$n-$RANDOM"; sess="hz-$unit-$kind-$n-$RANDOM"
  python3 - "$RUN_DIR/$sess.stats" "$uuid" "$kind" "$n" "$unit" "$wall" <<'PY'
import json, sys, time
path, uuid, kind, n, unit, wall = sys.argv[1:]
json.dump({"prefix": "hz", "repo": "acme/widget", "unit": unit, "issue": int(n), "kind": kind, "session": uuid,
           "launched": int(time.time()) - int(wall)}, open(path, "w"))
PY
  mkdir -p "$RUN_DIR/cfg/projects/p"
  python3 - "$RUN_DIR/cfg/projects/p/$uuid.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "bash test/test_hermetic.sh"}}]}}) + "\n")
    f.write(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "Exit code 137"}]}}) + "\n")
PY
  LAST_SESS="$sess"; LAST_UUID="$uuid"; }
labels(){ paste -sd, "$LABELS"; }
events(){ python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["event"]==sys.argv[2]: print(json.dumps(r))' "$HARNESS_EVENTS_FILE" "$1"; }

echo "=== every session dies young: the third trips the guard ==="
setup
end_session 541 bug-fix harness 200;      stats_sweep_ended 2>/dev/null
end_session 541 bug-fix priority-P1 300;  stats_sweep_ended 2>/dev/null
assert_eq "$(labels)" "agent-working" "two short sessions: the issue is left alone"
assert_eq "$(events churn | grep -c .)" "0" "two short sessions: no churn event"
assert_no "two short sessions: not parked" is_parked acme/widget 541
end_session 541 bug-fix harness 400;      stats_sweep_ended 2>/dev/null
assert_eq "$(labels)" "agent-blocked" "third short session: agent-working stripped, agent-blocked added"
assert_ok "third short session: parked" is_parked acme/widget 541
c="$RUN_DIR/comment.$(cat "$RUN_DIR/last-comment")"
assert_ok "the evidence comment starts with the marker" bash -c 'head -1 "$1" | grep -qx "<!-- harness-churn issue=541 -->"' _ "$c"
assert_ok "the comment lists the tool call and calls out SIGKILL" bash -c 'grep -q "test_hermetic.sh" "$1" && grep -q "SIGKILL (137)" "$1"' _ "$c"
assert_ok "the comment lists both lanes" bash -c 'grep -q "| harness |" "$1" && grep -q "| priority-P1 |" "$1"' _ "$c"
assert_eq "$(events churn | grep -c .)" "1" "exactly one churn event"
assert_eq "$(events churn | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); print(r["repo"], r["issue"], r["kind"], r["count"], r["window_min"], len(r["sessions"].split(",")))')" \
  "acme/widget 541 bug-fix 3 180 3" "the churn event names repo, issue, kind, count, window and the three sessions"
# the park record was written LAST: its updatedAt is the issue's current one, so nothing the engine did lifts it
assert_eq "$(cut -f4 "$(parked_file)")" "$(gh issue view 541 -R acme/widget --json updatedAt -q .updatedAt)" \
  "the park record carries the updatedAt read after the guard's own edits"
retry_pending_unlocks
assert_ok "retry_pending_unlocks leaves the park standing" is_parked acme/widget 541
# the unchanged issue is held from every claim path (real issuelib over a snapshot)
SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
python3 - "$SNAP" "$(gh issue view 541 -R acme/widget --json updatedAt -q .updatedAt)" <<'PY'
import json, sys, time
iss = lambda n, labels, upd: {"number": n, "title": f"t{n}", "state": "OPEN", "body": "",
    "labels": [{"name": l} for l in labels], "author": {"login": "bot"}, "updatedAt": upd}
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget",
           "issues": [iss(541, ["bug-triaged", "agent-blocked"], sys.argv[2]),
                      iss(542, ["bug-triaged"], "2026-10-28T00:00:00Z")],
           "has_plan": False, "plan_marker": None, "self_login": "bot", "ext_deps": {}, "issue_branches": []},
          open(sys.argv[1], "w"))
PY
# the poller sees the issue exactly as the guard left it: nothing changed it since the park
assert_eq "$(python3 "$ISSUELIB" bugs acme/widget 2>/dev/null | cut -f1 | paste -sd, -)" "542" \
  "bug_lane_candidates skips the parked issue and offers the other bug"

echo "=== the next session after a lift does not re-trip at once ==="
echo $(( $(cat "$UPD") + 5 )) > "$UPD"; echo "agent-blocked" > "$LABELS"; : > "$RUN_DIR/parked"   # a human edited it
echo "agent-working" > "$LABELS"
end_session 541 bug-fix harness 100; stats_sweep_ended 2>/dev/null
assert_eq "$(labels)" "agent-working" "first short session after the lift: no trip"
assert_eq "$(events churn | grep -c .)" "1" "still one churn event"

echo "=== no false trips on the reap path ==="
setup
end_session 7 bug-fix harness 100;  stats_sweep_ended 2>/dev/null
end_session 7 bug-fix harness 100;  stats_sweep_ended 2>/dev/null
echo CLOSED > "$STATE"
end_session 7 bug-fix harness 100;  stats_sweep_ended 2>/dev/null
assert_eq "$(labels)" "agent-working" "a goal-met session (issue closed) does not trip"
echo OPEN > "$STATE"
setup
end_session 8 bug-triage harness 100; stats_sweep_ended 2>/dev/null
end_session 8 bug-triage harness 100; stats_sweep_ended 2>/dev/null
echo "agent-working,bug-triaged" | tr ',' '\n' > "$LABELS"
end_session 8 bug-triage harness 100; stats_sweep_ended 2>/dev/null
assert_ok "a triage that flipped the issue to bug-triaged does not trip" bash -c '! grep -qx agent-blocked "$1"' _ "$LABELS"
setup
end_session 9 bug-fix harness 100;  stats_sweep_ended 2>/dev/null
end_session 9 bug-fix harness 100;  stats_sweep_ended 2>/dev/null
end_session 9 bug-fix harness 100; date +%s > "$RUN_DIR/$LAST_SESS.checkpoint"; stats_sweep_ended 2>/dev/null
assert_eq "$(labels)" "agent-working" "a checkpointed session ($LAST_SESS.checkpoint present) does not trip"
setup
end_session 10 bug-fix harness 100; stats_sweep_ended 2>/dev/null
end_session 10 bug-fix harness 100; stats_sweep_ended 2>/dev/null
end_session 10 bug-fix harness 1000; stats_sweep_ended 2>/dev/null
assert_eq "$(labels)" "agent-working" "a session at or over the max wall does not trip"

echo "=== off switch ==="
setup; export HARNESS_CHURN_COUNT=0
for i in 1 2 3 4; do end_session 11 bug-fix harness 100; stats_sweep_ended 2>/dev/null; done
assert_eq "$(labels)" "agent-working" "COUNT=0: nothing changes"
assert_eq "$(events churn | grep -c .)" "0" "COUNT=0: no churn event"
assert_eq "$(grep -c 'issue comment' "$GHLOG")" "0" "COUNT=0: no comment"
unset HARNESS_CHURN_COUNT

echo "=== impl lane: reap_impl_lane keeps the park the guard wrote ==="
setup; UNIT=main; WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR/main-i12"; CHECKOUT="$RUN_DIR/co"
for i in 1 2 3; do end_session 12 impl main 120; done
mkdir -p "$WORKTREES_DIR/main-i12"
echo "agent-working" > "$LABELS"
reap_team 2>/dev/null
assert_eq "$(labels)" "agent-blocked" "reap_team over three dead impl sessions: blocked, not relaunchable"
assert_ok "and parked at the updatedAt after reap_impl_lane's own unlock" bash -c \
  '[[ "$(cut -f4 "$1")" == "$2" ]]' _ "$(parked_file)" "$(gh issue view 12 -R acme/widget --json updatedAt -q .updatedAt)"

echo "=== prompt carry-over ==="
setup
assert_eq "$(churn_prompt_block 541)" "" "no churn comment: empty block, rendered prompt unchanged"
printf '<!-- harness-churn issue=541 -->\n## harness: crash-loop guard parked this issue\n| 2026 | 200 | harness |\n' > "$RUN_DIR/churn-comment"
blk="$(churn_prompt_block 541)"
assert_ok "a churn comment: the block carries its evidence" grep -q 'crash-loop guard parked this issue' <<<"$blk"
assert_ok "a churn comment: the block says to find what killed the sessions first" grep -qi 'find out what killed' <<<"$blk"
assert_ok "a churn comment: the block warns against re-running the same command blindly" grep -qi 'blindly' <<<"$blk"
rm -f "$RUN_DIR/churn-comment"
for t in impl bug-fix bug-triage resume; do
  assert_ok "prompts/$t.md carries {{CHURN}}" grep -q '{{CHURN}}' "$HERE/../prompts/$t.md"
  assert_eq "$(render "$HERE/../prompts/$t.md" PROJECT=p DESC=d SLUG=s OWNER=o SPEC= PRD= UNIT=u ISSUE=5 BRANCH=b PROMISE=pr \
      LABEL_READY=r LABEL_PRD=p LABEL_REVIEWED=v LABEL_HITL=h LABEL_WORKING=w LABEL_PAUSED=pa LABEL_BUG=bug LABEL_BUG_TRIAGED=bt HANDOFF= SUBAGENT= SWARM= SWARM_SUITE= CHURN= | grep -c '{{CHURN}}')" "0" \
    "$t.md renders with an empty CHURN and leaves no token behind"
done

finish
