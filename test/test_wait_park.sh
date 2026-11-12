#!/usr/bin/env bash
# test_wait_park.sh — #1066: engine-owned waits. A lane that starts a long job writes a wait spec and ends its turn; the worker tick
# (here the same steps worker_tend runs: watchdog_session + wait_tend) resumes its session ONCE when the job exits or the deadline
# passes. The usage limit takes the same path for every CLI. Real detached headless runners replaying fake CLIs (claude's
# fake-claude, codex's fake-codex): no stubs between the engine and the lane.
#   1. ACCEPTANCE: a lane that starts a (30-minute) job makes exactly ONE model call between starting it and getting the result:
#      the driven goal loop is armed and the engine ticks all along, and still nothing wakes the lane until the job exits.
#   2. The deadline resumes it too; a busy lane is never resumed mid-turn; a spec of a dead lane is void.
#   3. ACCEPTANCE: a lane on a NON-Claude adapter (codex) that hits the usage limit is parked, and resumed once after the usage
#      hold clears (and its reset time has passed); two parked lanes are resumed staggered, not in the same tick.
#   4. The goal-loop hooks (claude's Stop hook, goal_loop.py and its codex copy) let a waiting lane stop; the supervisor leaves
#      its quiet pane alone.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
export RUN_DIR HARNESS_SESS_PREFIX=wpk HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
export HARNESS_STALL_RETRIES=3 HARNESS_LIMIT_NUDGE_EVERY=1 HARNESS_INTERRUPT_WAIT=10 HARNESS_WAIT_STAGGER_S=0 HARNESS_WAIT_JITTER_S=0
CLAUDE_FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
CODEX_FAKE="$HERE/fixtures/cli/codex/stream-json/fake-codex"
export HARNESS_CLAUDE_BIN="python3 $(native_path "$CLAUDE_FAKE")" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_CODEX_BIN="python3 $(native_path "$CODEX_FAKE")"
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }
limit_checkpoint_once(){ :; }   # its mechanical checkpoint commits and comments on GitHub (usage.sh)
WAITLIB="$ROOT/scripts/waitlib.py"

our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
    [[ -f "$d/pids" ]] && tr ' ' '\n' < "$d/pids"
    [[ -f "$d/job.pid" ]] && cat "$d/job.pid"
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
# lane <name> <cli> <plan…> — a worktree and a fake-CLI dir replaying <plan> (one fixture per turn).
lane(){ local name="$1" cli="$2"; shift 2
  WD="$RUN_DIR/wd-$name"; mkdir -p "$WD"; echo "the task" > "$WD/.harness-task.md"
  FAKE_DIR="$RUN_DIR/fake-$name"; mkdir -p "$FAKE_DIR"; export FAKE_CLAUDE_DIR="$FAKE_DIR" HARNESS_CLI="$cli"
  printf '%s\n' "$@" > "$FAKE_DIR/plan"; }
calls_of(){ python3 -c 'import json,sys; [print(json.dumps(json.loads(l)[sys.argv[2]])) for l in open(sys.argv[1])]' "$1/calls.jsonl" "$2" 2>/dev/null; }
nturns(){ calls_of "$FAKE_DIR" prompt | wc -l | tr -d ' '; }
prompt_n(){ calls_of "$FAKE_DIR" prompt | sed -n "$1p"; }
pane_idle(){ local p; p="$(sess_capture "$1")" && cli_pane_prompt "$p" && ! cli_pane_busy "$p"; }
turn_is(){ [[ "$(python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$1")" --field turn)" == "$2" ]] && pane_idle "$1"; }
# tick <sess> — what the worker's lane tend does for a live lane: the watchdog, then the wait.
tick(){ watchdog_session "$1"; wait_tend "$1"; }
spec_set(){ python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p, k, v = sys.argv[1:]; d = json.load(open(p)); d[k] = json.loads(v); json.dump(d, open(p, "w"))
PY
}

echo "== 1. a lane that starts a 30-minute job makes exactly one model call between starting it and getting the result =="
S=wpk-main-i21; : > "$LOG"
lane i21 claude normal "normal <promise>ISSUE 21 DONE</promise>"
# the first turn starts the job the way a lane does (harness-wait run) and ends; the second must be the wake-up
cat > "$FAKE_DIR/turn-hook" <<EOF
#!/usr/bin/env bash
p="\$(cat)"
case "\$p" in *"wait done"*) exit 0;; esac
python3 "$WAITLIB" run --deadline-s 1800 --log "$FAKE_DIR/job.log" -- bash -c 'echo \$\$ > "$FAKE_DIR/job.pid"; until [ -e "$FAKE_DIR/release" ]; do sleep 0.1; done; echo "1234 passed"; exit 0'
EOF
chmod +x "$FAKE_DIR/turn-hook"
PROMISE="ISSUE 21 DONE" MAXITER=10 GOAL=ISSUE:21 launch_agent "$S" "$WD" >/dev/null 2>&1   # the driven goal loop is ARMED
assert_ok "the lane's environment names its wait file" grep -qF "$RUN_DIR/$S.wait" <<<"$(tr '\0' '\n' < "/proc/$(cat "$(headless_lane_dir "$S")/pid")/environ" 2>/dev/null)"
assert_ok "turn 1 (the one that starts the job) ends" wait_until 15 turn_is "$S" 1
assert_ok "…leaving a wait spec for the job" test -s "$RUN_DIR/$S.wait"
dl=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(int(d["deadline"]-d["created"]))' "$RUN_DIR/$S.wait")
assert_eq "$dl" "1800" "…with a 30-minute deadline"
assert_eq "$(nturns)" "1" "one model call so far: the one that started the job"
for (( i = 0; i < 12; i++ )); do tick "$S"; sleep 0.2; done   # ticks while the job runs (it waits on a release file): the goal loop is armed, nothing may call the model
assert_eq "$(nturns)" "1" "12 engine ticks while the job runs: still no model call (no goal-loop re-prompt, no nudge)"
assert_ok "the spec still stands" test -s "$RUN_DIR/$S.wait"
touch "$FAKE_DIR/release"   # the job finishes
assert_ok "the job exits" wait_until 20 bash -c "python3 '$WAITLIB' check --file '$RUN_DIR/$S.wait' >/dev/null"
tick "$S"
assert_ok "the next tick resumes the lane: its second turn" wait_until 15 turn_is "$S" 2
assert_eq "$(nturns)" "2" "exactly one model call between starting the job and getting the result"
assert_ok "…its message is the result: condition, rc, log tail" grep -qE '^"wait done: pid [0-9]+ exited, rc=0, log tail: 1234 passed"$' <<<"$(prompt_n 2)"
assert_no "…the spec is spent" test -e "$RUN_DIR/$S.wait"
for (( i = 0; i < 6; i++ )); do tick "$S"; sleep 0.1; done
assert_eq "$(nturns)" "2" "the lane answered with its promise: no further turn, the resume was once"
assert_ok "the engine logged the wake" grep -qF "wait: $S — wait done: pid" "$LOG"
sess_kill "$S"

echo "== 2a. the deadline resumes a lane whose job never ends =="
S=wpk-main-i22; : > "$LOG"
lane i22 claude normal normal
GOAL=ISSUE:22 launch_agent "$S" "$WD" >/dev/null 2>&1 && rm -f "$WD/.claude/ralph-loop.local.md"
assert_ok "the lane's first turn ends" wait_until 15 turn_is "$S" 1
sleep 300 & SLEEPER=$!; echo "$SLEEPER" > "$FAKE_DIR/job.pid"
python3 "$WAITLIB" set --file "$RUN_DIR/$S.wait" --deadline-s 6 --pid "$SLEEPER" --log "$FAKE_DIR/none.log" >/dev/null
tick "$S"; assert_eq "$(nturns)" "1" "before the deadline: not resumed"
sleep 6.3; tick "$S"
assert_ok "past the deadline: resumed" wait_until 15 turn_is "$S" 2
assert_ok "…naming the deadline" grep -qF "wait done: deadline passed (pid $SLEEPER" <<<"$(prompt_n 2)"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
for (( i = 0; i < 4; i++ )); do tick "$S"; done
assert_eq "$(nturns)" "2" "…once"

echo "== 2b. a lane that is still working is never resumed mid-turn =="
S=wpk-main-i23
lane i23 claude normal normal
touch "$FAKE_DIR/hold"
GOAL=ISSUE:23 launch_agent "$S" "$WD" >/dev/null 2>&1 && rm -f "$WD/.claude/ralph-loop.local.md"
assert_ok "the turn is running" wait_until 10 bash -c "source '$HERE/helpers.sh' >/dev/null 2>&1; true"
wait_until 10 bash -c "test -s '$FAKE_DIR/calls.jsonl'"
python3 "$WAITLIB" set --file "$RUN_DIR/$S.wait" --deadline-s 600 --path "$WD/.harness-task.md" >/dev/null   # already true
for (( i = 0; i < 4; i++ )); do tick "$S"; sleep 0.1; done
assert_eq "$(nturns)" "1" "its condition holds, but the busy lane gets nothing"
assert_ok "…and the spec waits" test -s "$RUN_DIR/$S.wait"
rm -f "$FAKE_DIR/hold"
assert_ok "the turn ends" wait_until 15 turn_is "$S" 1
tick "$S"
assert_ok "now it is idle: resumed once" wait_until 15 turn_is "$S" 2
assert_ok "…naming the file" grep -qF "wait done: file $WD/.harness-task.md appeared" <<<"$(prompt_n 2)"

echo "== 2c. a spec whose lane is gone is void; a new launch starts with none =="
python3 "$WAITLIB" set --file "$RUN_DIR/$S.wait" --deadline-s 600 --path "$RUN_DIR/never" >/dev/null
sess_kill "$S"
wait_sweep
assert_no "wait_sweep drops the dead lane's wait" test -e "$RUN_DIR/$S.wait"
python3 "$WAITLIB" set --file "$RUN_DIR/$S.wait" --deadline-s 600 --winsma 9 --resume redispatch >/dev/null
wait_sweep
assert_ok "…but not a redispatch park (winsma_wake_tick's: its session ended on purpose)" test -s "$RUN_DIR/$S.wait"
rm -f "$RUN_DIR/$S.wait"

echo "== 2d. a wait spec that is not the lane's own (a test wrote it into the lane's file, #1084) is dropped and the lane resumed =="
S=wpk-main-i26; : > "$LOG"
lane i26 claude normal normal
GOAL=ISSUE:26 launch_agent "$S" "$WD" >/dev/null 2>&1 && rm -f "$WD/.claude/ralph-loop.local.md"
assert_ok "the lane's first turn ends" wait_until 15 turn_is "$S" 1
# the lane's identity, as the launch recorded it: issue 1084 of acme/lane (a review lane would carry the PRD too)
spec_set "$RUN_DIR/$S.stats" issue '"1084"'; spec_set "$RUN_DIR/$S.stats" repo '"acme/lane"'; spec_set "$RUN_DIR/$S.stats" prd '""'
park(){ python3 "$WAITLIB" set --file "$RUN_DIR/$S.wait" --winsma "$1" --slug "$2" --label waiting-winsma --resume redispatch --deadline-s 600 >/dev/null; }
park 1084 acme/lane
for (( i = 0; i < 3; i++ )); do tick "$S"; done
assert_ok "a winsma park of the lane's own issue and repo is kept (winsma_wake_tick's)" test -s "$RUN_DIR/$S.wait"
assert_eq "$(nturns)" "1" "…and the lane is not resumed"
spec_set "$RUN_DIR/$S.stats" issue '""'; spec_set "$RUN_DIR/$S.stats" prd '"1084"'; park 1084 acme/lane
tick "$S"
assert_ok "a review park (the spec's issue is the lane's PRD) is kept" test -s "$RUN_DIR/$S.wait"
assert_eq "$(nturns)" "1" "…and the lane is not resumed"
spec_set "$RUN_DIR/$S.stats" issue '"1084"'; spec_set "$RUN_DIR/$S.stats" prd '""'
python3 "$WAITLIB" set --file "$RUN_DIR/$S.wait" --deadline-s 600 --path "$RUN_DIR/never" >/dev/null
tick "$S"
assert_ok "a job spec (no issue field) is untouched" test -s "$RUN_DIR/$S.wait"
assert_eq "$(nturns)" "1" "…and the lane is not resumed"
park 900 acme/widget; mv "$RUN_DIR/$S.stats" "$RUN_DIR/$S.stats.away"
tick "$S"
assert_ok "with no .stats file to judge by, a foreign-looking spec is kept" test -s "$RUN_DIR/$S.wait"
assert_eq "$(nturns)" "1" "…and the lane is not resumed"
mv "$RUN_DIR/$S.stats.away" "$RUN_DIR/$S.stats"
tick "$S"
assert_no "a spec naming another issue and repo (#900 acme/widget) is removed even with resume=redispatch" test -e "$RUN_DIR/$S.wait"
assert_ok "…and the lane is resumed" wait_until 15 turn_is "$S" 2
assert_ok "…told its wait spec was replaced by a foreign one, and to re-arm its wait" grep -qE 'wait spec was replaced by a foreign one.*re-arm' <<<"$(prompt_n 2)"
assert_ok "…the log names the session and the foreign issue and repo" grep -qE "wait: $S — .*#900.*acme/widget.*\(#1084\)" "$LOG"
assert_eq "$(grep -c "wait: $S — .*acme/widget" "$LOG")" "1" "…one line"
for (( i = 0; i < 4; i++ )); do tick "$S"; done
assert_eq "$(nturns)" "2" "…and once"
park 1084 acme/other
tick "$S"
assert_no "the right issue in another repo is foreign too" test -e "$RUN_DIR/$S.wait"
assert_ok "…and the lane is resumed" wait_until 15 turn_is "$S" 3
sess_kill "$S"

echo "== 3. a lane on a non-Claude adapter (codex) that hits the usage limit is parked and resumed once after the hold clears =="
S=wpk-main-i31; : > "$LOG"
lane i31 codex limit "normal <promise>ISSUE 31 DONE</promise>"
PROMISE="ISSUE 31 DONE" MAXITER=10 GOAL=ISSUE:31 launch_agent "$S" "$WD" >/dev/null 2>&1
assert_ok "the codex lane's first turn hits the usage limit" wait_until 20 bash -c "[[ \"\$(python3 '$ROOT/scripts/cli/claude_headless.py' state --lane '$(headless_lane_dir "$S")' --field state)\" == limit ]]"
assert_eq "$(python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$S")" --field adapter)" "codex" "…it is a codex lane"
assert_ok "the screen reads as parked at the limit" session_limit_idle "$(sess_capture "$S")"
for (( i = 0; i < 6; i++ )); do tick "$S"; done        # HARNESS_LIMIT_NUDGE_EVERY=1: the old watchdog nudged on EVERY one of these
assert_ok "the watchdog parked it (one log line)" grep -qF "watchdog: $S parked at its idle prompt by the usage limit — resumed once after the usage hold clears" "$LOG"
assert_eq "$(grep -c 'parked at its idle prompt by the usage limit' "$LOG")" "1" "…once, not every poll"
assert_eq "$(nturns)" "1" "6 polls at the limit: no nudge turn, no model call"
assert_ok "the spec is a limit wait on the codex account" bash -c "[[ \"\$(python3 '$WAITLIB' fields --file '$RUN_DIR/$S.wait' cond account | cut -f1,2)\" == \$'limit\tcodex' ]]"
nb=$(python3 "$WAITLIB" fields --file "$RUN_DIR/$S.wait" not_before | cut -f1); nb=${nb%%.*}
assert_ok "…not before the reset time the codex message named (an hour out)" test "$nb" -gt "$(( $(date +%s) + 3000 ))"
# the reset time passes, but the account's usage hold still stands
mkdir -p "$(_usage_hold_dir)"; printf 'codex\t5h\t99\t%s\n' "$(( $(date +%s) + 60 ))" > "$(_usage_hold_dir)/codex.hold"
spec_set "$RUN_DIR/$S.wait" not_before 1
for (( i = 0; i < 4; i++ )); do tick "$S"; done
assert_eq "$(nturns)" "1" "reset time passed but the usage hold stands: still parked"
rm -f "$(_usage_hold_dir)/codex.hold"
# another account's hold does not hold this lane
printf 'other\t5h\t99\t%s\n' "$(( $(date +%s) + 60 ))" > "$(_usage_hold_dir)/other.hold"
tick "$S"
assert_ok "a hold on ANOTHER account does not keep it parked: resumed" wait_until 15 turn_is "$S" 2
rm -f "$(_usage_hold_dir)/other.hold"
assert_eq "$(nturns)" "2" "the hold cleared: resumed with one model call"
assert_ok "…the message says the limit cleared" grep -qF "wait done: usage limit cleared, rc=-" <<<"$(prompt_n 2)"
for (( i = 0; i < 6; i++ )); do tick "$S"; sleep 0.1; done
assert_eq "$(nturns)" "2" "…and it is resumed once: later ticks send nothing"
sess_kill "$S"

echo "== 3b. a hold with no reading for the lane's account: any hold keeps it parked =="
S=wpk-main-i32; : > "$LOG"
lane i32 codex limit normal
GOAL=ISSUE:32 launch_agent "$S" "$WD" >/dev/null 2>&1 && rm -f "$WD/.claude/ralph-loop.local.md"
wait_until 20 bash -c "[[ \"\$(python3 '$ROOT/scripts/cli/claude_headless.py' state --lane '$(headless_lane_dir "$S")' --field state)\" == limit ]]"
tick "$S"; spec_set "$RUN_DIR/$S.wait" not_before 1; spec_set "$RUN_DIR/$S.wait" account '""'
printf 'x\t5h\t99\t%s\n' "$(( $(date +%s) + 60 ))" > "$(_usage_hold_dir)/x.hold"
tick "$S"; assert_eq "$(nturns)" "1" "an unknown account is held by any hold"
rm -f "$(_usage_hold_dir)/x.hold"; tick "$S"
assert_ok "…and resumed once none stands" wait_until 15 turn_is "$S" 2
sess_kill "$S"

echo "== 3c. lanes parked together are resumed staggered, not in the same tick =="
export HARNESS_WAIT_STAGGER_S=6   # wide: a tick on a loaded host takes seconds, and the window must outlast both
SA=wpk-main-i33; SB=wpk-main-i34; : > "$LOG"
lane i33 codex limit normal; FA="$FAKE_DIR"; WA="$WD"
GOAL=ISSUE:33 launch_agent "$SA" "$WD" >/dev/null 2>&1 && rm -f "$WD/.claude/ralph-loop.local.md"
lane i34 codex limit normal; FB="$FAKE_DIR"; WB="$WD"
GOAL=ISSUE:34 launch_agent "$SB" "$WD" >/dev/null 2>&1 && rm -f "$WD/.claude/ralph-loop.local.md"
for S in $SA $SB; do wait_until 20 bash -c "[[ \"\$(python3 '$ROOT/scripts/cli/claude_headless.py' state --lane '$(headless_lane_dir "$S")' --field state)\" == limit ]]"; tick "$S"; spec_set "$RUN_DIR/$S.wait" not_before 1; done
rm -f "$RUN_DIR/wait-stagger.stamp"
tick "$SA"; tick "$SB"
assert_no "the first lane to tick is resumed: its park is spent" test -e "$RUN_DIR/$SA.wait"
assert_ok "…the second waits for its slot: its park stands" test -s "$RUN_DIR/$SB.wait"
assert_ok "the first lane's resume is its second turn" wait_until 15 bash -c "[[ \$(wc -l < '$FA/calls.jsonl') -ge 2 ]]"
assert_eq "$(wc -l < "$FB/calls.jsonl" | tr -d ' ')" "1" "…the second lane has had no model call"
for (( i = 0; i < 40; i++ )); do tick "$SB"; [[ -e "$RUN_DIR/$SB.wait" ]] || break; sleep 0.5; done
assert_no "after the stagger window the second is resumed too" test -e "$RUN_DIR/$SB.wait"
assert_ok "…as its second turn" wait_until 15 bash -c "[[ \$(wc -l < '$FB/calls.jsonl') -ge 2 ]]"
export HARNESS_WAIT_STAGGER_S=0
sess_kill "$SA"; sess_kill "$SB"

echo "== 3d. a lane back at work on its own drops its park =="
S=wpk-main-i35; : > "$LOG"
lane i35 codex limit normal
GOAL=ISSUE:35 launch_agent "$S" "$WD" >/dev/null 2>&1 && rm -f "$WD/.claude/ralph-loop.local.md"
wait_until 20 bash -c "[[ \"\$(python3 '$ROOT/scripts/cli/claude_headless.py' state --lane '$(headless_lane_dir "$S")' --field state)\" == limit ]]"
tick "$S"; assert_ok "parked" test -s "$RUN_DIR/$S.wait"
spec_set "$RUN_DIR/$S.wait" not_before 1
cli_send "$S" "$WD" "carry on by hand" ; wait_until 15 turn_is "$S" 2
tick "$S"
assert_no "the park is dropped when the lane is no longer at the limit" test -e "$RUN_DIR/$S.wait"
assert_eq "$(nturns)" "2" "…and nothing more was sent"
sess_kill "$S"

echo "== 4. the goal-loop hooks let a waiting lane stop =="
HOOKDIR="$RUN_DIR/hookwd"; mkdir -p "$HOOKDIR/.claude"
printf -- '---\niteration: 1\nmax_iterations: 10\ncompletion_promise: "DONE"\nsession_id: abc\n---\nthe task\n' > "$HOOKDIR/.claude/ralph-loop.local.md"
hook_out(){ printf '{"cwd":"%s","session_id":"abc","last_assistant_message":"still waiting"}' "$HOOKDIR" | HARNESS_WAIT_FILE="$1" python3 "$2" 2>/dev/null; }
W="$RUN_DIR/hook.wait"; rm -f "$W" "$W.msg"
for h in "$ROOT/scripts/goal_loop.py" "$ROOT/plugins/codex/harness-ralph/hooks/stop-hook.py" "$ROOT/plugins/claude/harness-ralph/hooks/stop-hook.py"; do
  n="${h#$ROOT/}"
  assert_ok "$n: with no wait it re-feeds a reply without the promise" grep -q '"decision": *"block"' <<<"$(hook_out "$W" "$h")"
  : > "$W"; echo "x" > "$W"
  assert_eq "$(hook_out "$W" "$h")" "" "$n: with a wait spec standing it lets the turn end (no re-feed)"
  rm -f "$W"; echo "wait done: x" > "$W.msg"
  assert_eq "$(hook_out "$W" "$h")" "" "$n: …and while the resume message is on its way"
  rm -f "$W.msg"
  printf -- '---\niteration: 1\nmax_iterations: 10\ncompletion_promise: "DONE"\nsession_id: abc\n---\nthe task\n' > "$HOOKDIR/.claude/ralph-loop.local.md"
done
assert_ok "goal_loop.py and Codex's copy of it stay byte for byte one file (#307)" cmp -s "$ROOT/scripts/goal_loop.py" "$ROOT/plugins/codex/harness-ralph/hooks/stop-hook.py"
assert_ok "opencode's loop plugin yields to a wait too" grep -qF 'HARNESS_WAIT_FILE' "$ROOT/scripts/cli/opencode-ralph.js"
assert_ok "the supervisor leaves a lane parked on a wait alone" grep -qF '.wait.msg' "$ROOT/scripts/supervise.sh"
assert_ok "worker_tend runs wait_tend for an impl and an orch lane, and the bug lane tend does too" bash -c "[[ \$(grep -c 'wait_tend' '$ROOT/scripts/pool-worker.sh') -ge 3 ]] && grep -q 'wait_tend' '$ROOT/scripts/drive.sh'"
assert_ok "the chores sweep dead lanes' waits" grep -qF 'wait_sweep' "$ROOT/scripts/pool-worker.sh"
assert_ok "harness-wait is on every lane's PATH (lane-bin)" test -x "$ROOT/scripts/lane-bin/harness-wait"

finish
