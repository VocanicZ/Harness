#!/usr/bin/env bash
# test_lane_tend_tick.sh — #594 (PRD #587 §1): a worker that owns a live lane tends it on a ~15s tick, not a POLL.
#   1. the goal check runs only while the lane's pane is idle; a busy pane, or an idle one with a running
#      sub-agent, is never checked. The footer's `← 1 agent` is on every pane, so it is not that signal (#668)
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
# Real captures, unmodified (#668): every Claude Code pane shows `← 1 agent` in its footer, a sub-agent running or not.
busy(){ cp "$FIX/busy-spinner.txt" "$PANE"; }; idle(){ cp "$FIX/idle.txt" "$PANE"; }
idle_agent(){ cp "$FIX/idle-subagent-running.txt" "$PANE"; }   # at its prompt, a background sub-agent running
idle_agent_done(){ cp "$FIX/idle-subagent-done.txt" "$PANE"; }   # the same lane after the sub-agent ended (its old Waiting line is in the scrollback)

echo "=== 1. the goal check runs only while the pane is idle ==="
setup; S=hz-main-i5; own impl-5 "$S" IMPL:5
busy;       TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "0" "busy pane: check_session_goal not called"
idle_agent; TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "0" "idle prompt + running sub-agent: not called"
idle;       TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "1" "real idle.txt (footer still says ← 1 agent), no sub-agent: called (#668)"
idle_agent_done; TEND_FAST=1 worker_tend W1; assert_eq "$(count goal)" "2" "sub-agent finished (old Waiting line in scrollback, footer unchanged): called (#668)"
assert_eq "$(count watchdog)" "0" "the short tick does not run the stall watchdog (its counter counts POLLs)"
TEND_FAST=0 worker_tend W1; assert_eq "$(count goal)" "3" "a full tend checks the goal unconditionally (unchanged)"
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

echo "=== 8. #668: <sess>.idleticks does not outlive the session (reap, kill, launch) ==="
# A later session of the same name inherits the idle count and would pass the DECOMPOSE idle guard early.
setup; S=hz-main-i5; own impl-5 "$S" IMPL:5; idle
remove_worktree(){ :; }; unlock_issue(){ :; }; one_lease_live(){ return 1; }; gh(){ echo '{"state":"OPEN","labels":[]}'; }
unset -f reap_impl_lane reap_orch_lane watchdog_session check_session_goal
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; _HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
log(){ :; }; stats_sess_event(){ echo "event $1 $2" >> "$CALLS"; }; sess_live(){ grep -qxF "$1" "$LIVE"; }; session_live(){ sess_live "$1"; }
HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"; export HARNESS_EVENTS_FILE
stale(){ echo 2 > "$RUN_DIR/$1.idleticks"; }
S5="$(sess_impl "$UNIT" 5)"; stale "$S5"; : > "$LIVE"
reap_impl_lane 5
assert_ok "reaping an impl lane removes its .idleticks" test ! -f "$RUN_DIR/$S5.idleticks"
SP41="$(sess_orch "$UNIT" 41)"; stale "$SP41"; orch_worktree(){ echo "$RUN_DIR/wt/orch41"; }
reap_orch_lane 41
assert_ok "reaping an orch lane removes its .idleticks" test ! -f "$RUN_DIR/$SP41.idleticks"
echo "$SP41" >> "$LIVE"; echo "ISSUE:5" > "$RUN_DIR/$SP41.goal"; stale "$SP41"
python3(){ if [[ "${1:-}" == "$ISSUELIB" ]]; then echo DONE; else command python3 "$@"; fi; }
check_session_goal "$SP41"
unset -f python3
assert_ok "the lane was killed on its satisfied goal" test ! -f "$RUN_DIR/$SP41.goal"
assert_ok "... and a goal-satisfied kill removes its .idleticks" test ! -f "$RUN_DIR/$SP41.idleticks"
echo "-- a fresh launch of the same name starts at 0"
SL="$(sess_impl "$UNIT" 9)"; stale "$SL"; WD="$RUN_DIR/wd"; mkdir -p "$WD"; GOAL="ISSUE:9"; PROMISE=X; MAXITER=1
session_live(){ return 1; }; sess_start(){ return 1; }; sess_backend(){ echo tmux; }
ensure_trusted(){ :; }; write_state(){ :; }; lane_guard_env(){ :; }; lane_tmp_env(){ :; }; sess_resume_id(){ :; }
launch_agent "$SL" "$WD" >/dev/null 2>&1
assert_ok "launch_agent removes a stale .idleticks before the session starts" test ! -f "$RUN_DIR/$SL.idleticks"
echo "-- the watchdog's dead-session sweep too"
S2="$(sess_impl "$UNIT" 3)"; stale "$S2"; watchdog_session "$S2" >/dev/null 2>&1
assert_ok "watchdog_session on a dead session removes its .idleticks" test ! -f "$RUN_DIR/$S2.idleticks"

echo "=== 9. #721: an idle lane whose goal stays pending backs the goal check off ==="
setup 300; S=hz-main-i5; own impl-5 "$S" IMPL:5; idle   # the goal never lands: check_session_goal is only counted
for i in 1 2 3 4; do TEND_FAST=1 worker_tend W1; [[ $i == 1 ]] && assert_eq "$(count goal)" "1" "the first idle tick still checks (goal_satisfied within 30s)"; done
assert_eq "$(count goal)" "3" "ticks 1-4 idle: checks on ticks 1, 2 and 4 (doubling gap)"
for i in $(seq 5 40); do TEND_FAST=1 worker_tend W1; done   # 40 ticks of 15s = 10 minutes idle
G="$(count goal)"
assert_ok "10 idle minutes, goal pending: at most 8 checks, not 40 ($G)" test "$G" -le 8
assert_ok "... but not starved: at least 5 ($G)" test "$G" -ge 5
for i in $(seq 41 100); do TEND_FAST=1 worker_tend W1; done
assert_ok "the gap is capped at POLL: 100 ticks never wait more than 20 ticks between checks" test "$(( $(count goal) - G ))" -ge 3
echo "-- a busy pane resets the backoff: the next idle tick checks at once"
G="$(count goal)"; busy; TEND_FAST=1 worker_tend W1; idle; TEND_FAST=1 worker_tend W1
assert_eq "$(( $(count goal) - G ))" "1" "busy then idle: first idle tick checks again"
TEND_FAST=1 worker_tend W1; assert_eq "$(( $(count goal) - G ))" "2" "... and the second one, the gap restarting at one tick"
echo "-- DECOMPOSE backs off too, from its first eligible tick"
setup 300; S=hz-main-p41; own orch-41 "$S" DECOMPOSE:41; touch "$RUN_DIR/$S.d/.loop"; idle
for i in $(seq 1 12); do TEND_FAST=1 worker_tend W1; done
assert_eq "$(count goal)" "4" "12 idle ticks: checks on ticks 3, 4, 6, 10 (idle guard, then doubling)"
echo "-- POLL at the short tick: no backoff room, every tick checks"
setup 15; S=hz-main-i5; own impl-5 "$S" IMPL:5; idle
for i in 1 2 3 4; do TEND_FAST=1 worker_tend W1; done
assert_eq "$(count goal)" "4" "cap is 1 tick when POLL <= the tick"
echo "-- the backoff state is one file, removed with the idle count"
setup; S=hz-main-i5; own impl-5 "$S" IMPL:5; idle; TEND_FAST=1 worker_tend W1; busy; TEND_FAST=1 worker_tend W1
assert_ok "busy tick removes .idleticks (and the backoff with it)" test ! -f "$RUN_DIR/$S.idleticks"

echo "=== 10. #782: a HARNESS_TEND_TICK / HARNESS_TEND_IDLE_TICKS that is not a number falls back to the default and warns once ==="
for bad in abc 15s -5 ""; do
  setup 300; S=hz-main-i5; own impl-5 "$S" IMPL:5; busy
  log(){ echo "log $*" >> "$CALLS"; }
  HARNESS_TEND_TICK="$bad"; worker_step W1 >/dev/null 2>&1; rc=$?; worker_step W1 >/dev/null 2>&1
  assert_eq "$rc" "1" "TEND_TICK='$bad': the first step runs through to the (stubbed idle) claim step — the worker survives"
  assert_eq "$HARNESS_TEND_TICK" "15" "TEND_TICK='$bad': falls back to 15"
  assert_eq "$(grep -c "^log WARN HARNESS_TEND_TICK='$bad' is not a non-negative integer" "$CALLS")" "1" "TEND_TICK='$bad': one warning naming knob and value"
  assert_eq "$(grep -c "^sleep 15$" "$CALLS")" "2" "TEND_TICK='$bad': an owner of a live lane tends on the 15s tick"
  setup; S=hz-main-p41; own orch-41 "$S" DECOMPOSE:41; touch "$RUN_DIR/$S.satisfied" "$RUN_DIR/$S.d/.loop"; idle
  log(){ echo "log $*" >> "$CALLS"; }
  HARNESS_TEND_IDLE_TICKS="$bad"; worker_step W1 >/dev/null 2>&1; worker_step W1 >/dev/null 2>&1
  assert_eq "$HARNESS_TEND_IDLE_TICKS" "3" "IDLE_TICKS='$bad': falls back to 3"
  assert_eq "$(grep -c "^log WARN HARNESS_TEND_IDLE_TICKS='$bad' is not a non-negative integer" "$CALLS")" "1" "IDLE_TICKS='$bad': one warning naming knob and value"
done
echo "-- 0 and valid values are kept, silently"
setup; log(){ echo "log $*" >> "$CALLS"; }
HARNESS_TEND_TICK=0; HARNESS_TEND_IDLE_TICKS=0; tend_knobs
assert_eq "$HARNESS_TEND_TICK/$HARNESS_TEND_IDLE_TICKS" "0/0" "0 keeps its meaning"
HARNESS_TEND_TICK=007; HARNESS_TEND_IDLE_TICKS=20; tend_knobs
assert_eq "$HARNESS_TEND_TICK/$HARNESS_TEND_IDLE_TICKS" "7/20" "valid values kept (leading zeros read as decimal)"
assert_eq "$(count log)" "0" "...no warning"
for big in 9223372036854775807 9223372036854775808 99999999999999999999 18446744073709551616 86401; do
  setup; S=hz-main-p41; own orch-41 "$S" DECOMPOSE:41; touch "$RUN_DIR/$S.satisfied" "$RUN_DIR/$S.d/.loop"; idle
  log(){ echo "log $*" >> "$CALLS"; }
  HARNESS_TEND_IDLE_TICKS="$big"; tend_knobs
  assert_eq "$HARNESS_TEND_IDLE_TICKS" "3" "#800: IDLE_TICKS='$big' is too large: falls back to 3 (no wrap to 0 / negative)"
  assert_eq "$(grep -c "^log WARN HARNESS_TEND_IDLE_TICKS='$big' is not a non-negative integer" "$CALLS")" "1" "#800: IDLE_TICKS='$big': one warning naming knob and value"
done
HARNESS_TEND_IDLE_TICKS=86400; tend_knobs; assert_eq "$HARNESS_TEND_IDLE_TICKS" "86400" "#800: the cap itself is kept"

echo "=== 11. #799: TEND_TICK=0 (or an overflow to <= 0) is 'tend every POLL': an owner of a live lane sleeps POLL, never sleep 0 ==="
for v in 0 18446744073709551616; do
  setup 300; S=hz-main-i5; own impl-5 "$S" IMPL:5; busy
  HARNESS_TEND_TICK="$v"; for i in 1 2 3; do worker_step W1 >/dev/null 2>&1; done
  assert_eq "$(grep -c "^sleep 300$" "$CALLS")" "3" "TEND_TICK=$v: three idle steps sleep POLL each"
  assert_eq "$(grep -Ec "^sleep (0|-)" "$CALLS")" "0" "TEND_TICK=$v: no sleep 0 / negative sleep"
  assert_eq "$(count chores)" "3" "TEND_TICK=$v: full steps, one per POLL"
  assert_eq "$NOW" "1900" "TEND_TICK=$v: the clock advances POLL per step"
done
echo "-- an overflow to a negative: the first step sleeps POLL (no failing negative sleep); #782 then replaces it with 15"
setup 300; S=hz-main-i5; own impl-5 "$S" IMPL:5; busy
HARNESS_TEND_TICK=9223372036854775808; worker_step W1 >/dev/null 2>&1
assert_eq "$(tail -1 "$CALLS")" "sleep 300" "TEND_TICK=2^63: sleeps POLL, not a negative number"

echo "=== 12. #883: a reap found by the FULL step does not sleep POLL before the next step ==="
# The full step runs chores, then tend: a lane its tend reaps frees a slotless chore (CLOSE_PRD) that those chores already missed.
setup 300; S=hz-main-i5; own impl-5 "$S" IMPL:5; idle; touch "$RUN_DIR/$S.satisfied"
worker_step W1 >/dev/null   # first step is full: chores, tend reaps (the goal check is not idle-gated), tick finds nothing (rc 1)
assert_ok "the full step's tend reaped the lane" grep -q "^reap impl-5" "$CALLS"
assert_eq "$(grep -c "^sleep 300$" "$CALLS")" "0" "no POLL sleep after the reap"
REAP_AT="$NOW"; C0="$(count chores)"
worker_step W1 >/dev/null   # the follow-up: a full step at once, running the chores again
assert_eq "$(( $(count chores) - C0 ))" "1" "the follow-up step ran the chores again"
LAST_CH="$(grep '^chores@' "$CALLS" | tail -1)"; LAST_CH="${LAST_CH#chores@}"
assert_ok "... within 30s of the reap, so a slotless CLOSE_PRD lands in time ($((LAST_CH - REAP_AT))s after)" test "$((LAST_CH - REAP_AT))" -le 30
assert_eq "$(tail -1 "$CALLS")" "sleep 300" "nothing to do after the follow-up: an idle worker sleeps POLL as before"
C1="$(count chores)"; worker_step W1 >/dev/null
assert_eq "$(grep -c "^sleep 300$" "$CALLS")" "2" "no back-to-back loop: each further idle step sleeps POLL"
assert_eq "$(( $(count chores) - C1 ))" "1" "... one full step each"
echo "-- a reap while the worker still owns another lane keeps the short tick"
setup 300; S=hz-main-i5; own impl-5 "$S" IMPL:5; idle; touch "$RUN_DIR/$S.satisfied"
S2=hz-main-i6; own impl-6 "$S2" IMPL:6; busy_one(){ :; }
worker_step W1 >/dev/null
assert_eq "$(tail -1 "$CALLS")" "sleep 15" "another lane live: tends it on the short tick, no POLL"

finish
