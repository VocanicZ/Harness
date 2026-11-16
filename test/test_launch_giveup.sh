#!/usr/bin/env bash
# test_launch_giveup.sh — #1183 (PRD #1180): three consecutive launch failures of one issue / PRD stop the retries.
# Bench run-20261115 run 05 logged `launch_failed start_failed` on issue #2 once per poll for the whole 6 h cap and scored 0/80.
#   1. three start failures in a row (a fake clock, the real backoff schedule): the third gives the issue up — a `launch_giveup`
#      event with the key, count and reason, a log line, agent-blocked + a comment on the issue, a park record — and claim_lane stops
#      offering it while another issue still dispatches; the hold ends after 6 h and the count starts afresh
#   2. the default knobs give up inside 10 minutes: the real backoff schedule, a worker that sleeps launch_retry_secs after a failed
#      spawn, and a launch attempt that itself takes 72 s (what the bench measured)
#   3. a lane that really ran (or met its goal) clears the count: failures with a run between them do not add up
#   4. HARNESS_LAUNCH_FAIL_MAX: 1 gives up at once, 0 never, a bad value falls back to 3 with a warning
#   5. a lane gone within seconds (session_gone) counts like a start failure; a PRD key is labelled; orch-0 is held locally only
#   6. `harness status` (churn.py status) lists a give-up until a lane of the key launches again; stats ignores the event
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/scripts/lib.sh"; source "$ROOT/scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$ROOT/scripts/pool-worker.sh"; source "$HERE/helpers.sh"
T="$(mktemp -d /tmp/t1183.XXXXXX)"
trap 'rm -rf "$T"' EXIT

not(){ ! "$@"; }
restore(){ source "$ROOT/scripts/lib.sh"; source "$ROOT/scripts/drive.sh"; source "$ROOT/scripts/pool-worker.sh"; }
setup(){
  restore; make_env
  unset HARNESS_LAUNCH_FAIL_MAX HARNESS_LAUNCH_BACKOFF HARNESS_LAUNCH_BACKOFF_MAX HARNESS_LAUNCH_FAIL_SECS
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; HARNESS_UNIT=""
  POOL=2; POLL=300; HARNESS_USE_POLLER=0; HARNESS_CHECKOUT="$RUN_DIR/co"; mkdir -p "$HARNESS_CHECKOUT"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude HARNESS_CI_GATE=0
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"; export HARNESS_EVENTS_FILE; : > "$HARNESS_EVENTS_FILE"
  HARNESS_PARKED_FILE="$RUN_DIR/parked"; export HARNESS_PARKED_FILE
  NOW=5000; date(){ if [[ "${1:-}" == +%s ]]; then echo "$NOW"; else command date "$@"; fi; }
  LOGF="$RUN_DIR/log.txt"; : > "$LOGF"; log(){ echo "$*" >> "$LOGF"; }; fleet_ctx; mkdir -p "$CLAIMS_DIR"
  GHLOG="$RUN_DIR/gh.log"; : > "$GHLOG"; export GHLOG
  gh(){ echo "gh $*" >> "$GHLOG"; case "$*" in *"issue view"*) echo '{"state":"OPEN","labels":[]}';; esac; return 0; }; export -f gh
  remove_worktree(){ :; }; one_lease_live(){ return 1; }
  ensure_checkout(){ :; }; busy_prds_for(){ :; }; busy_issues_for(){ :; }; is_claimed(){ [[ -f "$CLAIMS_DIR/$1.claim" ]]; }
  session_live(){ return 1; }; sess_start(){ return 1; }; sess_backend(){ echo tmux; }
  ensure_trusted(){ :; }; write_state(){ :; }; lane_guard_env(){ :; }; lane_tmp_env(){ :; }; sess_resume_id(){ :; }
}
evs(){ python3 -c 'import json,sys
for l in open(sys.argv[1]): print(json.loads(l).get("event"), end=" ")' "$HARNESS_EVENTS_FILE"; }
ev_count(){ python3 -c 'import json,sys
print(sum(1 for l in open(sys.argv[1]) if json.loads(l).get("event") == sys.argv[2]))' "$HARNESS_EVENTS_FILE" "$1"; }
giveup_field(){ python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e.get("event") == "launch_giveup": print(e.get(sys.argv[2], "")); break' "$HARNESS_EVENTS_FILE" "$1"; }
snap(){ python3 - "$SNAP" "$@" <<'PY'
import json, sys, time
path, nums = sys.argv[1], sys.argv[2:]
issues = [{"number": int(n), "title": f"t{n}", "state": "OPEN", "body": "## What to build\nx\n",
           "labels": [{"name": "ready-for-agent"}], "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"} for n in nums]
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget", "issues": issues, "has_plan": False,
           "plan_marker": None, "self_login": "bot", "ext_deps": {}, "issue_branches": []}, open(path, "w"))
PY
}
# fail_start <issue> — one launch attempt of the issue whose backend cannot start the session (what spawn_impl's launch does)
fail_start(){ local sess; sess="$(sess_impl "$UNIT" "$1")"; GOAL="ISSUE:$1"; PROMISE=X; MAXITER=1; launch_agent "$sess" "$RUN_DIR/wd$1" >/dev/null; }

echo "== 1. three start failures in a row give the issue up =="
setup; snap 7 8; mkdir -p "$RUN_DIR/wd7"; T0=$NOW
for round in 1 2; do
  assert_eq "$(claim_lane W1 | cut -f1,2)" "IMPL	7" "attempt $round: #7 is claimed"
  fail_start 7; rm -f "$CLAIMS_DIR/impl-7.claim"
  assert_eq "$(ev_count launch_giveup)" "0" "…its start failed: still retried (no give-up after $round)"
  assert_eq "$(claim_lane W1 | cut -f1,2)" "IMPL	8" "…during its backoff the other issue #8 is claimed meanwhile"
  rm -f "$CLAIMS_DIR/impl-8.claim"
  NOW=$((NOW + 60 * (1 << (round - 1)) + 1))
done
assert_eq "$(claim_lane W1 | cut -f1,2)" "IMPL	7" "attempt 3: #7 is claimed"
fail_start 7; rm -f "$CLAIMS_DIR/impl-7.claim"; ELAPSED=$((NOW - T0))
assert_eq "$(ev_count launch_giveup)" "1" "the third consecutive start failure logs one launch_giveup"
assert_eq "$(ev_count launch_failed)" "3" "…after three launch_failed"
assert_eq "$(giveup_field key)" "impl-7" "…naming the claim key"
assert_eq "$(giveup_field count)" "3" "…the count"
assert_eq "$(giveup_field reason)" "start_failed" "…and the last reason"
assert_eq "$(giveup_field issue)" "7" "…and the issue"
assert_ok "…the log line says it gave up" grep -q "launch of impl-7 failed 3 times in a row (last: start_failed) — giving up" "$LOGF"
assert_ok "…the issue is labelled agent-blocked" grep -q "gh issue edit 7 -R acme/widget --add-label agent-blocked" "$GHLOG"
assert_ok "…agent-working is stripped" grep -q "gh issue edit 7 -R acme/widget --remove-label agent-working" "$GHLOG"
assert_ok "…and a comment says why (the count and the reason)" grep -q "after 3 consecutive launch failures (last reason: \`start_failed\`)" "$GHLOG"
assert_ok "…and who may release it" grep -q "no lane takes it until someone comments on it or edits its labels" "$GHLOG"
assert_ok "…the issue is parked (nothing changed it since)" is_parked acme/widget 7
assert_ok "…the park comes after the label edit and the comment" bash -c '[[ "$(grep -n "add-label agent-blocked" "$1" | cut -d: -f1)" -lt "$(grep -n "issue comment 7" "$1" | cut -d: -f1)" ]]' _ "$GHLOG"
NOW=$((NOW + 5000))
snap 7
assert_eq "$(claim_lane W1 | cut -f1,2)" "" "5000 s later (far past any backoff) #7 is still not offered: it is given up"
snap 7 8
assert_eq "$(claim_lane W1 | cut -f1,2)" "IMPL	8" "…while #8 still dispatches"
rm -f "$CLAIMS_DIR/impl-8.claim"
assert_eq "$(backoff_keys impl)" "7" "…backoff_keys keeps #7 out of dispatch's owned list"
assert_ok "…on the fake clock ($ELAPSED s after the first failure, every wait taken in full) it is under 10 minutes" test "$ELAPSED" -lt 600
NOW=$((NOW + 21600))
assert_eq "$(claim_lane W1 | cut -f1,2)" "IMPL	7" "after the 6 h hold #7 is claimed again"
rm -f "$CLAIMS_DIR/impl-7.claim" "$CLAIMS_DIR/impl-8.claim"
assert_no "…and its old count is gone" test -e "$RUN_DIR/launchfail.impl-7"
fail_start 7
assert_eq "$(cut -d' ' -f2 "$RUN_DIR/launchfail.impl-7")" "1" "…a failure after the hold counts from 1"
assert_eq "$(ev_count launch_giveup)" "1" "…and gives nothing up again"

echo "== 2. the default knobs give up inside 10 minutes =="
setup; snap 7; mkdir -p "$RUN_DIR/wd7"
# the worker loop on a fake clock: claim, a launch attempt of 72 s that fails, then worker_step's sleep after a failed spawn
T0=$NOW; fails=0; t3=""; POLL=300
for i in 1 2 3 4 5 6; do
  got="$(claim_lane W1 | cut -f1,2)"
  if [[ -z "$got" ]]; then NOW=$((NOW + $(launch_retry_secs "$POLL"))); continue; fi
  NOW=$((NOW + 72)); fail_start 7; rm -f "$CLAIMS_DIR/impl-7.claim"; fails=$((fails + 1))
  (( fails == 3 )) && { t3=$((NOW - T0)); break; }
  NOW=$((NOW + $(launch_retry_secs "$POLL")))
done
assert_eq "$fails" "3" "three launch attempts failed"
assert_ok "…the third at $t3 s, under 10 minutes (600 s) after the first attempt began" test "$t3" -lt 600
assert_eq "$(ev_count launch_giveup)" "1" "…and that third failure gave the issue up"
NOW=$((NOW + $(launch_retry_secs "$POLL")))
assert_eq "$(claim_lane W1 | cut -f1,2)" "" "…no fourth attempt"
# the sleep a failed spawn leaves
setup; launch_backoff_mark impl-7
assert_eq "$(launch_retry_secs 300)" "61" "after the first failure the worker sleeps 61 s (backoff 60 + 1), not POLL"
NOW=$((NOW + 10)); assert_eq "$(launch_retry_secs 300)" "51" "…the time left of the backoff"
assert_eq "$(launch_retry_secs 30)" "30" "…never more than POLL"
NOW=$((NOW + 100)); assert_eq "$(launch_retry_secs 300)" "300" "…POLL once the backoff is over (no spin)"
launch_backoff_mark impl-7; launch_backoff_mark impl-7
assert_eq "$(launch_retry_secs 300)" "300" "a given-up key has no backoff to wait for: POLL"
rm -f "$RUN_DIR"/launchfail.*
assert_eq "$(launch_retry_secs 300)" "300" "no failure at all: POLL"
setup; launch_backoff_mark impl-7; NOW=$((NOW + 1)); launch_backoff_mark impl-9
assert_eq "$(launch_retry_secs 300)" "60" "two keys in backoff: the soonest to end (impl-7's, 59 s + 1)"
# the schedule itself, by arithmetic on the real knobs
setup; w1="$(_launch_wait 1)"; w2="$(_launch_wait 2)"
assert_eq "$w1 $w2" "60 120" "the default backoff after failure 1 and 2 is 60 s and 120 s"
assert_ok "…so three failures with 72 s attempts take $(( 72 * 3 + w1 + w2 )) s of 600" test $(( 72 * 3 + w1 + w2 )) -lt 600

echo "== 3. a lane that really ran clears the count =="
setup; snap 7; mkdir -p "$RUN_DIR/wd7"
fail_start 7; fail_start 7
assert_eq "$(cut -d' ' -f2 "$RUN_DIR/launchfail.impl-7")" "2" "two failures: count 2"
S7="$(sess_impl "$UNIT" 7)"; echo "$((NOW - 400)) uuid-7" > "$RUN_DIR/$S7.launched"
reap_impl_lane 7
assert_no "a lane that ran 400 s is reaped: the count is cleared" test -e "$RUN_DIR/launchfail.impl-7"
fail_start 7; fail_start 7
assert_eq "$(ev_count launch_giveup)" "0" "two more failures after the run do not give the issue up (not consecutive with the first two)"
echo "$((NOW - 2)) uuid-7" > "$RUN_DIR/$S7.launched"; : > "$RUN_DIR/$S7.goalmet"
reap_impl_lane 7
assert_no "a lane gone in 2 s whose goal was met clears the count too" test -e "$RUN_DIR/launchfail.impl-7"
fail_start 7; fail_start 7; fail_start 7
assert_eq "$(ev_count launch_giveup)" "1" "three failures in a row after that give it up"

echo "== 4. HARNESS_LAUNCH_FAIL_MAX =="
setup; HARNESS_LAUNCH_FAIL_MAX=1 launch_backoff_mark impl-7 start_failed
assert_eq "$(ev_count launch_giveup)" "1" "MAX=1: the first failure gives up"
setup; export HARNESS_LAUNCH_FAIL_MAX=0
for i in 1 2 3 4 5 6; do launch_backoff_mark impl-7 start_failed; done
assert_eq "$(ev_count launch_giveup)" "0" "MAX=0: never gives up (six failures)"
NOW=$((NOW + 1000)); assert_no "…the doubling backoff alone: over after 1000 s" launch_backoff_active impl-7
setup; export HARNESS_LAUNCH_FAIL_MAX=5
for i in 1 2 3 4; do launch_backoff_mark impl-7 start_failed; done
assert_eq "$(ev_count launch_giveup)" "0" "MAX=5: four failures do not give up"
launch_backoff_mark impl-7 start_failed
assert_eq "$(ev_count launch_giveup)" "1" "…the fifth does"
for bad in abc 3s -1 1.5 99999999999999999999 100000; do
  setup; export HARNESS_LAUNCH_FAIL_MAX="$bad"
  launch_backoff_mark impl-7 start_failed; launch_backoff_mark impl-7 start_failed
  assert_eq "$(ev_count launch_giveup)" "0" "MAX='$bad': two failures do not give up (falls back to 3)"
  launch_backoff_mark impl-7 start_failed
  assert_eq "$(ev_count launch_giveup)" "1" "…the third does"
  assert_ok "…with a warning naming the knob" grep -q "WARN HARNESS_LAUNCH_FAIL_MAX='$bad' is not a non-negative integer — using the default 3" "$LOGF"
  assert_eq "$(grep -c "WARN HARNESS_LAUNCH_FAIL_MAX" "$LOGF")" "1" "…once"
done
unset HARNESS_LAUNCH_FAIL_MAX

echo "== 5. session_gone, a PRD and the PLAN / PRD session =="
setup; snap 7; export HARNESS_LAUNCH_FAIL_MAX=3
S7="$(sess_impl "$UNIT" 7)"
for i in 1 2 3; do echo "$((NOW - 2)) uuid-$i" > "$RUN_DIR/$S7.launched"; launch_gone_check "$S7" impl issue=7; NOW=$((NOW + 200)); done
assert_eq "$(ev_count launch_failed)" "3" "three lanes gone 2 s after launch: three launch_failed"
assert_eq "$(giveup_field reason)" "session_gone" "…the give-up names session_gone"
assert_eq "$(giveup_field key)" "impl-7" "…and the key"
assert_ok "…the issue is labelled and commented" grep -q "gh issue comment 7 " "$GHLOG"
setup
for i in 1 2 3; do launch_backoff_mark orch-4 start_failed; done
assert_eq "$(giveup_field prd)" "4" "a PRD key's give-up event carries prd=4"
assert_ok "…the PRD is labelled agent-blocked" grep -q "gh issue edit 4 -R acme/widget --add-label agent-blocked" "$GHLOG"
assert_eq "$(backoff_keys orch)" "4" "…and kept out of dispatch's busy PRD list"
setup
for i in 1 2 3; do launch_backoff_mark orch-0 start_failed; done
assert_eq "$(ev_count launch_giveup)" "1" "the PLAN / PRD session (orch-0): given up as well"
assert_eq "$(giveup_field key)" "orch-0" "…its key"
assert_eq "$(giveup_field issue)$(giveup_field prd)" "" "…with no issue or PRD number"
assert_eq "$(grep -c "gh " "$GHLOG")" "0" "…and no gh call (there is nothing to label)"
assert_ok "…it is held locally" launch_backoff_active orch-0
NOW=$((NOW + 21600)); assert_no "…for 6 h" launch_backoff_active orch-0
assert_no "…and the stale mark is dropped" test -e "$RUN_DIR/launchfail.orch-0"

echo "== 6. status lists it, stats ignores it =="
setup
for i in 1 2 3; do launch_backoff_mark impl-7 start_failed; done
out="$(python3 "$ROOT/scripts/churn.py" status --fleet hz --events "$HARNESS_EVENTS_FILE")"
assert_ok "status names the issue, the count and the reason" grep -q "acme/widget#7 given up: 3 launches failed in a row (last: start_failed)" <<<"$out"
assert_ok "…and how to release it" grep -q "comment on it or edit its labels" <<<"$out"
assert_eq "$(python3 "$ROOT/scripts/churn.py" status --fleet other --events "$HARNESS_EVENTS_FILE")" "" "another fleet sees nothing"
python3 - "$HARNESS_EVENTS_FILE" <<'PY'
import json, sys, time
open(sys.argv[1], "a").write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600)), "event": "launch", "prefix": "hz",
    "repo": "acme/widget", "kind": "impl", "issue": 7, "prd": 1, "session": "s"}) + "\n")
PY
assert_eq "$(python3 "$ROOT/scripts/churn.py" status --fleet hz --events "$HARNESS_EVENTS_FILE" | grep -c given)" "0" "a later launch of #7 ends the row"
setup
for i in 1 2 3; do launch_backoff_mark orch-0 start_failed; done
assert_ok "an orch-0 give-up is listed too" grep -q "acme/widget PLAN/PRD session given up" <<<"$(python3 "$ROOT/scripts/churn.py" status --fleet hz --events "$HARNESS_EVENTS_FILE")"

finish
