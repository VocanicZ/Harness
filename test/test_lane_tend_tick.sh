#!/usr/bin/env bash
# test_lane_tend_tick.sh — #594 (PRD #587 §1): a worker that owns a live lane tends it on a ~15s tick, not a POLL.
#   1. the goal check runs only while the lane's pane is idle; a busy pane, or an idle one with a running
#      sub-agent (`← 1 agent`), is never checked
#   2. a fake lane replayed on a 15s clock: goal_satisfied within 30s of the pane going idle, and the next
#      claim within 30s of the reap
#   3. fleet-wide chores (and the watchdog) keep the POLL cadence, not the short tick
#   4. a DECOMPOSE lane that filed 1 of N children and is idle for one tick is not reaped; it ends on its
#      completion promise, or after N idle ticks with no gh running
# Real worker_step / worker_tend / tend_lane_done over a stubbed tmux, gh and clock; the pane text is real fixtures.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"; source "$HERE/helpers.sh"
FIX="$HERE/fixtures/cli/claude"

restore(){ source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/../scripts/pool-worker.sh"; }
setup(){  # [poll]
  restore; make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; HARNESS_UNIT=""
  POOL=1; POLL="${1:-300}"; HARNESS_TEND_TICK=15; HARNESS_TEND_IDLE_TICKS=3; HARNESS_USE_POLLER=0
  HARNESS_CHECKOUT="$RUN_DIR/co"; mkdir -p "$HARNESS_CHECKOUT"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude HARNESS_CI_GATE=0
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LIVE="$RUN_DIR/live"; : > "$LIVE"; PANE="$RUN_DIR/pane"; GH_RUNNING="$RUN_DIR/gh_running"; rm -f "$GH_RUNNING"
  export CALLS LIVE; NOW=1000; _LAST_FULL=
  log(){ :; }; stats_sess_event(){ echo "event $1 $2" >> "$CALLS"; }
  sess_live(){ grep -qxF "$1" "$LIVE"; }; session_live(){ sess_live "$1"; }
  sess_capture(){ cat "$PANE"; }
  sess_pane_pid(){ echo 4242; }
  lane_has_gh(){ [[ -f "$GH_RUNNING" ]]; }
  cli_kill(){ echo "kill $1" >> "$CALLS"; grep -vxF "$1" "$LIVE" > "$LIVE.n"; mv "$LIVE.n" "$LIVE"; }
  check_session_goal(){ echo "goal $1" >> "$CALLS"; if [[ -f "$RUN_DIR/$1.satisfied" ]]; then
      stats_sess_event "$1" goal_satisfied; cli_kill "$1"; rm -f "$RUN_DIR/$1.goal"; fi; }
  watchdog_session(){ echo "watchdog $1" >> "$CALLS"; }
  reap_impl_lane(){ session_live "$(sess_impl "$UNIT" "$1")" && return 1; echo "reap impl-$1" >> "$CALLS"; return 0; }
  reap_orch_lane(){ session_live "$(sess_orch "$UNIT" "$1")" && return 1; echo "reap orch-$1" >> "$CALLS"; return 0; }
  # the step's other parts: counted, not run
  roots_check(){ :; }; gc_orphan_goals(){ :; }; gh_rate_wait(){ :; }; usage_watch(){ :; }; snapshot_gate(){ return 0; }
  worker_chores(){ echo "chores@$NOW" >> "$CALLS"; }
  worker_tick(){ echo "tick@$NOW" >> "$CALLS"; return 1; }
  sleep(){ echo "sleep $1" >> "$CALLS"; NOW=$(( NOW + $1 )); }
  date(){ if [[ "${1:-}" == +%s ]]; then echo "$NOW"; else command date "$@"; fi; }
  cli_done(){ [[ ! -f "$1/.loop" ]]; }
  fleet_ctx; mkdir -p "$CLAIMS_DIR"
}
own(){ # <key> <session> <goal> — the worker W1 holds a claim on a live lane
  echo "$2" >> "$LIVE"; echo "$3" > "$RUN_DIR/$2.goal"; mkdir -p "$RUN_DIR/$2.d/"; echo "$RUN_DIR/$2.d" > "$RUN_DIR/$2.wd"
  lane_claim_write "$1" W1 "${3/#/}" "$2" "-"; }
count(){ grep -c "^$1" "$CALLS"; }
busy(){ cp "$FIX/busy-spinner.txt" "$PANE"; }; idle(){ sed '/← 1 agent/d' "$FIX/idle.txt" > "$PANE"; }
idle_agent(){ cp "$FIX/idle.txt" "$PANE"; }

echo "=== 1. the goal check runs only while the pane is idle ==="
setup; S=hz-main-i5; own impl-5 "$S" IMPL:5
busy;       TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "0" "busy pane: check_session_goal not called"
idle_agent; TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "0" "idle prompt + running sub-agent (← 1 agent): not called"
idle;       TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "1" "idle pane, no sub-agent: called"
assert_eq "$(count watchdog)" "0" "the short tick does not run the stall watchdog (its counter counts POLLs)"
TEND_FAST=0 worker_tend W1; assert_eq "$(count goal)" "2" "a full tend checks the goal unconditionally (unchanged)"
assert_eq "$(count watchdog)" "1" "... and runs the watchdog"

echo "=== 2. a fake lane on the worker clock: goal_satisfied ≤30s after idle, next claim ≤30s after the reap ==="
setup 300; S=hz-main-i5; own impl-5 "$S" IMPL:5; busy
worker_step W1 >/dev/null   # full step (first): chores + tend + tick; the lane is busy
assert_eq "$(count chores)" "1" "first step is full"
assert_eq "$(tail -1 "$CALLS")" "sleep 15" "an owner of a live lane sleeps the short tick, not POLL"
G0="$(count goal)"
for i in 1 2 3; do worker_step W1 >/dev/null; done   # busy: three short ticks
assert_eq "$(( $(count goal) - G0 ))" "0" "no goal check while busy"
assert_eq "$(count chores)" "1" "no chores on short ticks"
idle; touch "$RUN_DIR/$S.satisfied"; IDLE_AT="$NOW"
while ! grep -q "^reap impl-5" "$CALLS" && (( NOW - IDLE_AT < 120 )); do worker_step W1 >/dev/null; done
assert_ok "goal_satisfied logged" grep -q "^event $S goal_satisfied" "$CALLS"
assert_ok "goal_satisfied within 30s of the pane going idle ($((NOW - IDLE_AT))s)" test $((NOW - IDLE_AT)) -le 30
assert_ok "lane reaped" grep -q "^reap impl-5" "$CALLS"
REAP_AT="$NOW"; before="$(count tick)"; C0="$(count chores)"
worker_step W1 >/dev/null   # the step after the reap: full, with no sleep first
assert_eq "$(count tick)" "$(( before + 1 ))" "the claim step ran right after the reap"
assert_ok "... within 30s of the reap ($((NOW - REAP_AT))s... clock at claim)" grep -q "^tick@$REAP_AT$" "$CALLS"
assert_eq "$(( $(count chores) - C0 ))" "1" "... as a full step (chores ran: a slotless CLOSE_PRD fires too)"

echo "=== 3. fleet-wide chores keep the POLL cadence ==="
setup 300; S=hz-main-i5; own impl-5 "$S" IMPL:5; busy
worker_step W1 >/dev/null; T0="$NOW"
while (( NOW - T0 < 270 )); do worker_step W1 >/dev/null; done
assert_eq "$(count chores)" "1" "no chore in the first 285s of short ticks"
worker_step W1 >/dev/null; worker_step W1 >/dev/null
assert_eq "$(count chores)" "2" "chores run again once POLL has passed"
assert_eq "$(count tick)" "2" "... and so does the claim step"
echo "-- no lane owned: POLL sleep as before"
setup 300; rm -f "$CLAIMS_DIR"/*.claim; worker_step W1 >/dev/null
assert_eq "$(tail -1 "$CALLS")" "sleep 300" "idle worker sleeps POLL"
echo "-- POLL below the short tick: POLL wins"
setup 5; S=hz-main-i5; own impl-5 "$S" IMPL:5; busy; worker_step W1 >/dev/null
assert_eq "$(tail -1 "$CALLS")" "sleep 5" "POLL=5 < 15: still every POLL"

echo "=== 4. DECOMPOSE: 1 of N children filed, idle for one tick: not reaped ==="
setup; S=hz-main-p41; own orch-41 "$S" DECOMPOSE:41; touch "$RUN_DIR/$S.satisfied"; touch "$RUN_DIR/$S.d/.loop"; idle
TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "0" "one idle tick: goal not checked, lane lives"
assert_ok "session still live" sess_live "$S"
TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "0" "two idle ticks: still not"
busy; TEND_FAST=1 worker_tend W1; idle
TEND_FAST=1 worker_tend W1; TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "0" "a busy tick resets the idle count"
touch "$GH_RUNNING"; TEND_FAST=1 worker_tend W1
assert_eq "$(count goal)" "0" "N idle ticks but gh running: not checked"
rm -f "$GH_RUNNING"; TEND_FAST=1 worker_tend W1
assert_eq "$(count goal)" "1" "N idle ticks, no gh running: checked"
assert_ok "... and reaped" bash -c "! grep -qxF '$S' '$LIVE'"
echo "-- the completion promise ends it at once"
setup; S=hz-main-p41; own orch-41 "$S" DECOMPOSE:41; touch "$RUN_DIR/$S.satisfied"; idle   # no .loop file: cli_done
TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "1" "promise printed (loop done): checked on the first idle tick"

echo "=== 5. REVIEW: idle prompt + running sub-agent is not reaped ==="
setup; S=hz-main-p41; own orch-41 "$S" REVIEW:41; touch "$RUN_DIR/$S.satisfied"; idle_agent
for i in 1 2 3 4; do TEND_FAST=1 worker_tend W1; done
assert_eq "$(count goal)" "0" "four idle ticks with a running sub-agent: never checked"
assert_ok "session still live" sess_live "$S"
idle; TEND_FAST=1 worker_tend W1
assert_eq "$(count goal)" "1" "sub-agent gone: checked (REVIEW has no promise gate)"

echo "=== 6. lane_has_gh: a real gh process under the pane pid (#653) ==="
setup; unset -f lane_has_gh; source "$HERE/../scripts/pool-worker.sh"; source "$HERE/../scripts/portable.sh"
mkdir -p "$RUN_DIR/stub"; printf '#!/bin/sh\nsleep 8\n' > "$RUN_DIR/stub/gh"; chmod +x "$RUN_DIR/stub/gh"
bash -c "( \"$RUN_DIR/stub/gh\" ) & wait" & HG=$!
bash -c "sleep 8 & wait" & HN=$!
sleep(){ command sleep "$@"; }
for _ in $(seq 1 40); do ps -e -o comm= | grep -qx gh && break; command sleep 0.05; done; command sleep 0.2
sess_pane_pid(){ echo "$HG"; }
assert_ok "gh descendant of the pane pid: lane_has_gh is 0" lane_has_gh any
sess_pane_pid(){ echo "$HN"; }
assert_no "no gh under the pane pid: lane_has_gh is 1" lane_has_gh any
sess_pane_pid(){ echo ""; }
assert_no "no pane pid: lane_has_gh is 1" lane_has_gh any
assert_no "pool-worker.sh has no raw ps -o (ADR 0001)" grep -nE '(^|[^[:alnum:]_.-])ps (-[a-zA-Z]*[[:space:]]+)*-[a-zA-Z]*o\b' "$HERE/../scripts/pool-worker.sh"

echo "=== 7. #667: the short tick's goal check reads gh, not a stale poller snapshot (real check_session_goal → issuelib check) ==="
# Real check_session_goal and issuelib over a SNAPSHOT-mode env (HARNESS_SNAPSHOT_FILE set, poller refresh far away)
# whose snapshot still says issue 5 is open, and a stub `gh` on PATH that records every call and says it is closed.
setup; S=hz-main-i5; own impl-5 "$S" ISSUE:5
source "$HERE/../scripts/drive.sh"   # the real check_session_goal, over setup's stub
BIN="$RUN_DIR/bin"; mkdir -p "$BIN"; GHLOG="$RUN_DIR/gh.log"; : > "$GHLOG"
cat > "$BIN/gh" <<'GH'
#!/bin/sh
echo "gh $*" >> "$GHLOG"
case "$*" in
  *"issue view 5"*) echo '{"state":"CLOSED","labels":[{"name":"agent-working"}]}';;
  *) echo '[]';;
esac
GH
chmod +x "$BIN/gh"
SNAP="$RUN_DIR/snap.json"
python3 - "$SNAP" <<'PY'
import json, sys, time
json.dump({"schema_version": 1, "slug": "acme/widget", "generated_at": time.time() - 590, "self_login": "bot",
           "issues": [{"number": 5, "state": "OPEN", "title": "t", "body": "", "labels": [{"name": "agent-working"}],
                       "author": {"login": "bot"}}]}, open(sys.argv[1], "w"))
PY
export GHLOG HARNESS_SNAPSHOT_FILE="$SNAP" HARNESS_SNAPSHOT_DIR="$RUN_DIR" HARNESS_PRIORITY_POLL=600 HARNESS_OWNER=acme
OLDPATH="$PATH"; PATH="$BIN:$PATH"
idle; TEND_FAST=1 worker_tend W1
assert_ok "stale snapshot says open, gh says closed: goal_satisfied on the idle short tick" grep -q "^event $S goal_satisfied" "$CALLS"
echo "-- the check itself: one gh issue view of that lane's issue, no whole-repo list"
setup; S=hz-main-i5; own impl-5 "$S" ISSUE:5; source "$HERE/../scripts/drive.sh"; : > "$GHLOG"
check_session_goal "$S" live
assert_eq "$(cat "$GHLOG")" "gh issue view 5 -R acme/widget --json state,labels" "live check: exactly one gh issue view"
assert_ok "... and it ended the lane" grep -q "^event $S goal_satisfied" "$CALLS"
setup; S=hz-main-i5; own impl-5 "$S" ISSUE:5; source "$HERE/../scripts/drive.sh"; : > "$GHLOG"
check_session_goal "$S"
assert_eq "$(wc -l < "$GHLOG" | tr -d ' ')" "0" "snapshot check (no live): no gh call, reads the stale snapshot"
assert_no "... so it stays PENDING" grep -q "goal_satisfied" "$CALLS"
echo "-- a busy pane: gh is not called on the tick"
setup; S=hz-main-i5; own impl-5 "$S" ISSUE:5; source "$HERE/../scripts/drive.sh"; : > "$GHLOG"; busy
TEND_FAST=1 worker_tend W1; TEND_FAST=1 worker_tend W1
assert_eq "$(wc -l < "$GHLOG" | tr -d ' ')" "0" "busy short ticks: no gh call"
echo "-- the full tend keeps reading the snapshot (the poller's cadence)"
idle; TEND_FAST=0 worker_tend W1
assert_eq "$(wc -l < "$GHLOG" | tr -d ' ')" "0" "full tend: snapshot read, no gh call"
assert_no "... and the stale snapshot says PENDING: not satisfied" grep -q "goal_satisfied" "$CALLS"
echo "-- a gh failure on the short tick keeps the lane (no answer)"
printf '#!/bin/sh\necho "gh $*" >> "$GHLOG"; echo "HTTP 502" >&2; exit 1\n' > "$BIN/gh"
idle; TEND_FAST=1 worker_tend W1
assert_ok "lane still live after a transient gh failure" sess_live "$S"
PATH="$OLDPATH"; unset HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR HARNESS_PRIORITY_POLL GHLOG

finish
