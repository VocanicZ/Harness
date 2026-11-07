#!/usr/bin/env bash
# test_watchdog_headless.sh — #493 / PRD #475 task 6: the headless twin of test_watchdog.sh (#115).
# test_watchdog.sh draws real tmux panes (section A classifies captured panes with session_stalled;
# B-C drive watchdog_session's nudge → kill escalation and its hands-off rules over a stubbed tmux).
# This asserts the SAME behaviour on the HEADLESS session backend (HARNESS_SESSION_BACKEND=headless),
# so it needs no tmux and runs on Windows: every lane here is a real detached runner
# (scripts/cli/claude_headless.py) replaying the fake claude of test/fixtures/cli/claude/stream-json/,
# and the watchdog reads its pane (sess_capture) and nudges/kills it through the real seam. No stubs.
#   1. session_stalled is true for the error-then-idle screen, false for a lane busy mid-turn (held
#      by the fake's hold file) and false for a healthy idle lane with no error.
#   2. watchdog_session nudges polls 1..K-1 (K = HARNESS_STALL_RETRIES=3, counter $RUN_DIR/$S.stall)
#      and kills at poll K: the lane is gone, the counter cleared, no further nudge delivered.
#   3. A busy lane and a healthy idle lane are never nudged or killed over K+1 polls, and the stall
#      counter resets on recovery, so a later stall counts from zero again.
# (test_headless_lane.sh already covers the limit park and a single transient nudge.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
export RUN_DIR HARNESS_SESS_PREFIX=hlt HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $(native_path "$FAKE")" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_STALL_RETRIES=3 HARNESS_LIMIT_NUDGE_EVERY=1 HARNESS_INTERRUPT_WAIT=10
K=$HARNESS_STALL_RETRIES
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }
limit_checkpoint_once(){ :; }   # its mechanical checkpoint commits and comments on GitHub (usage.sh)

# Only the processes this test started: each lane's runner (its pid file) and each fake claude
# (calls.jsonl / pids). Never a pattern kill: the host runs other lanes.
our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
    [[ -f "$d/pids" ]] && tr ' ' '\n' < "$d/pids"
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
# lane <name> <plan…> — a worktree and a fake-claude dir replaying <plan> (one fixture per turn).
lane(){ local name="$1"; shift
  WD="$RUN_DIR/wd-$name"; mkdir -p "$WD"; echo "the task" > "$WD/.harness-task.md"
  export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$name"; mkdir -p "$FAKE_CLAUDE_DIR"
  printf '%s\n' "$@" > "$FAKE_CLAUDE_DIR/plan"; }
calls(){ python3 -c 'import json,sys; [print(json.dumps(json.loads(l)[sys.argv[2]])) for l in open(sys.argv[1])]' \
  "$FAKE_CLAUDE_DIR/calls.jsonl" "$1" 2>/dev/null; }
nturns(){ calls prompt | wc -l | tr -d ' '; }
pane_busy(){ cli_pane_busy "$(sess_capture "$1")"; }
pane_idle(){ local p; p="$(sess_capture "$1")" && cli_pane_prompt "$p" && ! cli_pane_busy "$p"; }
turn_is(){ [[ "$(python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$1")" --field turn)" == "$2" ]] && pane_idle "$1"; }
stalled(){ session_stalled "$(sess_capture "$1")"; }
stall_count(){ cat "$RUN_DIR/$1.stall" 2>/dev/null; }
nudges(){ grep -cF "watchdog: $1 wedged at its idle prompt after a transient API error (poll" "$LOG"; }   # prints 0 (rc 1) on none
# launch <session> <issue> — launch_agent arms the driven goal loop, which would re-prompt a healthy turn
# that ended without its promise: a different feature (test_headless_lane.sh). Disarm it, so the only thing
# that can nudge or kill these lanes is the #115 stall watchdog under test.
launch(){ GOAL="ISSUE:$2" launch_agent "$1" "$WD" >/dev/null 2>&1 && rm -f "$WD/.claude/ralph-loop.local.md"; }

echo "== 1. session_stalled on a headless lane: busy mid-turn, healthy idle, error-then-idle =="
S=hlt-main-i1
lane i1 normal
touch "$FAKE_CLAUDE_DIR/hold"   # the turn waits mid-turn until released
assert_ok "the lane launches" launch "$S" 1
assert_ok "the held turn reads busy" wait_until 10 pane_busy "$S"
assert_no "session_stalled leaves a lane busy mid-turn alone" stalled "$S"
rm -f "$FAKE_CLAUDE_DIR/hold"
assert_ok "the turn ends, the lane reads idle" wait_until 15 turn_is "$S" 1
assert_no "session_stalled leaves a healthy idle lane (no error) alone" stalled "$S"
sess_kill "$S"
S=hlt-main-i2
lane i2 transient
assert_ok "an error-turn lane launches" launch "$S" 2
assert_ok "its turn ends in the transient error, the lane idle" wait_until 15 turn_is "$S" 1
assert_ok "the screen shows the API error" grep -qF "API Error: 529" <<<"$(sess_capture "$S")"
assert_ok "session_stalled detects the error-then-idle wedge" stalled "$S"
sess_kill "$S"

echo "== 2. watchdog_session escalates: nudge on polls 1..K-1, kill at poll K =="
S=hlt-main-i3; : > "$LOG"
lane i3 transient transient transient transient transient   # every nudge's turn ends in the error again
assert_ok "the lane launches" launch "$S" 3
assert_ok "turn 1 ends in the error, the lane idle" wait_until 15 turn_is "$S" 1
assert_ok "the lane is stalled" stalled "$S"
for (( i = 1; i < K; i++ )); do
  watchdog_session "$S"
  assert_eq "$(stall_count "$S")" "$i" "poll $i: stall counter = $i"
  assert_ok "poll $i: nudge logged (poll $i/$K)" grep -qF "watchdog: $S wedged at its idle prompt after a transient API error (poll $i/$K)" "$LOG"
  assert_ok "poll $i: the nudge runs as the lane's next turn" wait_until 15 turn_is "$S" $(( i + 1 ))
  assert_ok "poll $i: delivered as the transient nudge" grep -qF "the transient API error has cleared" <<<"$(calls prompt | sed -n "$((i + 1))p")"
  assert_ok "poll $i: not killed yet" sess_live "$S"
  assert_ok "poll $i: the nudge's turn is the error again" stalled "$S"
done
assert_eq "$(nudges "$S")" "$((K - 1))" "$((K - 1)) nudges before the kill"
watchdog_session "$S"   # poll K
assert_no "poll $K: the lane is killed (not live)" sess_live "$S"
assert_ok "poll $K: the kill is logged" grep -qF "watchdog: $S wedged at its idle prompt after a transient API error for $K polls — killing" "$LOG"
assert_no "poll $K: the stall counter is cleared" test -e "$RUN_DIR/$S.stall"
assert_eq "$(nudges "$S")" "$((K - 1))" "poll $K: no further nudge"
assert_eq "$(nturns)" "$K" "poll $K: no extra turn was delivered"
assert_eq "$(sess_list)" "" "no lane is listed afterwards"

echo "== 3a. a busy lane is never nudged or killed =="
S=hlt-main-i4; : > "$LOG"
lane i4 normal
touch "$FAKE_CLAUDE_DIR/hold"
assert_ok "the lane launches" launch "$S" 4
assert_ok "the held turn reads busy" wait_until 10 pane_busy "$S"
for (( i = 0; i <= K; i++ )); do watchdog_session "$S"; done
assert_eq "$(nudges "$S")" 0 "$((K + 1)) polls: busy lane never nudged"
assert_eq "$(nturns)" 1 "…no nudge turn delivered"
assert_ok "…never killed" sess_live "$S"
assert_no "…and leaves no stall counter" test -e "$RUN_DIR/$S.stall"
assert_no "…and logs no watchdog action" grep -qF "watchdog: $S" "$LOG"

echo "== 3b. a healthy idle lane is never nudged or killed =="
rm -f "$FAKE_CLAUDE_DIR/hold"
assert_ok "the turn ends, the lane reads idle" wait_until 15 turn_is "$S" 1
for (( i = 0; i <= K; i++ )); do watchdog_session "$S"; done
assert_eq "$(nudges "$S")" 0 "$((K + 1)) polls: healthy idle lane never nudged"
assert_eq "$(nturns)" 1 "…no nudge turn delivered"
assert_ok "…never killed" sess_live "$S"
assert_no "…and leaves no stall counter" test -e "$RUN_DIR/$S.stall"
assert_no "…and logs no watchdog action" grep -qF "watchdog: $S" "$LOG"
sess_kill "$S"

echo "== 3c. the stall counter resets on recovery, so a later stall counts from zero =="
S=hlt-main-i5; : > "$LOG"
lane i5 transient transient normal transient transient
assert_ok "the lane launches" launch "$S" 5
assert_ok "turn 1 ends in the error" wait_until 15 turn_is "$S" 1
watchdog_session "$S"; assert_ok "poll 1: nudge turn runs" wait_until 15 turn_is "$S" 2
watchdog_session "$S"; assert_ok "poll 2: nudge turn runs" wait_until 15 turn_is "$S" 3
assert_eq "$(stall_count "$S")" "$((K - 1))" "two consecutive stalls counted (K-1)"
assert_no "the recovered turn is not stalled" stalled "$S"
watchdog_session "$S"
assert_no "the stall counter is cleared once the lane recovers" test -e "$RUN_DIR/$S.stall"
assert_ok "…and the lane is still live" sess_live "$S"
assert_eq "$(nturns)" 3 "…with no nudge for the healthy turn"
cli_send "$S" "$WD" "go on"
assert_ok "a later turn ends in the error again" wait_until 15 turn_is "$S" 4
assert_ok "…and is stalled" stalled "$S"
watchdog_session "$S"
assert_eq "$(stall_count "$S")" 1 "the later stall counts from 1, not from K-1"
assert_ok "…and the lane survives it" sess_live "$S"
sess_kill "$S"

finish
