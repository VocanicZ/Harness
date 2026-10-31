#!/usr/bin/env bash
# test_headless_lane.sh — #349 / PRD #344: the headless session backend. With
# HARNESS_SESSION_BACKEND=headless, launch_agent starts a claude lane as a detached headless runner
# (scripts/cli/claude_headless.py) and every seam operation works on it: the fake claude from the
# runner's fixtures (test/fixtures/cli/claude/stream-json/) takes the bootstrap and a later cli_send,
# the lane reads busy → idle, the driven goal loop ends it on the promise, the watchdog sees its limit
# and transient states, an interrupt ends a running turn, attach follows it read-only, and
# `harness stop` leaves no lane process behind. A CLI with no headless runner is refused as tmux-only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
_DOCTOR_SOURCED=1 source "$ROOT/scripts/doctor.sh"
make_env
export RUN_DIR HARNESS_SESS_PREFIX=hlt HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $FAKE" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_STALL_RETRIES=3 HARNESS_LIMIT_NUDGE_EVERY=1 HARNESS_INTERRUPT_WAIT=10
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
alive(){ kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
# wait_until <seconds> <command…> — true once <command> is.
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
# lane <name> <plan…> — a worktree and a fake-claude dir replaying <plan> (one fixture per turn).
lane(){ local name="$1"; shift
  WD="$RUN_DIR/wd-$name"; mkdir -p "$WD"; echo "the task" > "$WD/.harness-task.md"
  export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$name"; mkdir -p "$FAKE_CLAUDE_DIR"
  printf '%s\n' "$@" > "$FAKE_CLAUDE_DIR/plan"; }
calls(){ python3 -c 'import json,sys; [print(json.dumps(json.loads(l)[sys.argv[2]])) for l in open(sys.argv[1])]' \
  "$FAKE_CLAUDE_DIR/calls.jsonl" "$1" 2>/dev/null; }
pane_busy(){ cli_pane_busy "$(sess_capture "$1")"; }
pane_idle(){ local p; p="$(sess_capture "$1")" && cli_pane_prompt "$p" && ! cli_pane_busy "$p"; }
turn_is(){ [[ "$(python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$1")" --field turn)" == "$2" ]] && pane_idle "$1"; }

echo "== launch_agent starts a headless lane; bootstrap, a later cli_send, busy → idle =="
S=hlt-main-i9
lane i9 normal "normal not yet" "normal <promise>ISSUE 9 DONE</promise>" hang normal hang
touch "$FAKE_CLAUDE_DIR/hold"   # the bootstrap turn waits mid-turn until released
PROMISE="ISSUE 9 DONE" MAXITER=10 GOAL=ISSUE:9 launch_agent "$S" "$WD"; rc=$?
assert_eq "$rc" 0 "launch_agent starts the lane"
assert_ok "the lane is live" sess_live "$S"
assert_eq "$(sess_list)" "$S" "sess_list lists it"
assert_eq "$(sess_list_paths)" "$S"$'\t'"$WD" "…with its start directory"
assert_eq "$(sess_panes)" "$S:0.0 headless" "sess_panes names it"
pid="$(sess_pane_pid "$S")"
assert_ok "its process id is the runner's, alive" alive "$pid"
assert_eq "$(cat "$RUN_DIR/$S.wd")" "$WD" "the .wd is recorded"
assert_eq "$(cat "$RUN_DIR/$S.goal")" "ISSUE:9" "…and the .goal"
uuid="$(sed -n 's/^session_id: //p' "$WD/.claude/ralph-loop.local.md")"
assert_ok "the bootstrap turn shows busy" wait_until 10 pane_busy "$S"
assert_eq "$(calls prompt | head -1)" "\"$HARNESS_BOOTSTRAP_PROMPT\"" "the first turn's prompt is the bootstrap, on stdin"
assert_ok "…run with the launch's session id" grep -qF "\"--session-id\", \"$uuid\"" <<<"$(calls argv | head -1)"
assert_ok "…and the configured flags" grep -qF '"--dangerously-skip-permissions"' <<<"$(calls argv | head -1)"
assert_ok "no launch line was typed: argv names no task text" test "$(calls argv | grep -c 'the task')" -eq 0
assert_eq "$(claude_loop)" driven "a headless claude lane runs the driven goal loop"
assert_no "the goal loop reads no reply while the turn runs" claude_last_reply "$WD" "$uuid"
cli_send "$S" "$WD" "a later message"
assert_ok "a cli_send mid-turn waits in the input box" grep -qxF "❯ a later message" <<<"$(sess_capture "$S")"
assert_no "…and nothing is left typed" test -e "$(headless_lane_dir "$S")/typed"
rm -f "$FAKE_CLAUDE_DIR/hold"
assert_ok "both turns run, and the lane reads idle" wait_until 15 turn_is "$S" 2
assert_eq "$(calls prompt | sed -n 2p)" '"a later message"' "the cli_send was delivered as the next turn"
assert_ok "…resuming the same session" grep -qF "\"--resume\", \"$uuid\"" <<<"$(calls argv | sed -n 2p)"
assert_eq "$(claude_last_reply "$WD" "$uuid")" "$uuid:2"$'\n'"not yet" "the goal loop reads the last turn's reply"

echo "== the driven goal loop ends on the promise =="
for (( i = 0; i < 100; i++ )); do cli_done "$WD" && break; watchdog_session "$S"; sleep 0.2; done
assert_ok "the goal loop ended (the state file is gone)" cli_done "$WD"
assert_ok "…after re-prompting the turn that ended without its promise" grep -qF "Ralph iteration 2" <<<"$(calls prompt | sed -n 3p)"
assert_ok "…with the bootstrap, never the task text" grep -qF "$HARNESS_BOOTSTRAP_PROMPT" <<<"$(calls prompt | sed -n 3p)"
assert_ok "the log says the loop ended" grep -qF "goal loop: $S ended its loop" "$LOG"
assert_ok "the lane stays live, idle" pane_idle "$S"

echo "== attach follows the lane read-only =="
assert_eq "$(sess_attach_hint "$S")" "harness attach $S" "attach hint"
out="$(timeout 3 bash "$ROOT/scripts/attach.sh" "$S" 2>&1)"
assert_ok "harness attach <session> watches the headless lane" grep -qF "watching headless lane $S" <<<"$out"
assert_ok "…showing its turns" grep -qF "── turn 1 (bootstrap)" <<<"$out"
assert_ok "…and its replies" grep -qF "← <promise>ISSUE 9 DONE</promise>" <<<"$out"
assert_eq "$(calls prompt | wc -l)" 3 "attaching typed nothing into the lane"

echo "== interrupt ends a running turn, and the lane takes the next message =="
cli_send "$S" "$WD" "start the long one"
assert_ok "the hang turn is running" wait_until 10 test -s "$FAKE_CLAUDE_DIR/pids"
fpid=; gpid=; [[ -f "$FAKE_CLAUDE_DIR/pids" ]] && read -r fpid gpid < "$FAKE_CLAUDE_DIR/pids"
sess_type "$S" "Please continue — after the interrupt"; sess_enter "$S"
assert_ok "the queued nudge shows in the input box" grep -qF "❯ Please continue — after the interrupt" <<<"$(sess_capture "$S")"
# The nudge's own turn is held, as a real `claude -p` turn takes seconds: turn_interrupt reads the
# `Interrupted` line while the next turn runs (the TUI's scrollback keeps it the same way).
touch "$FAKE_CLAUDE_DIR/hold"
assert_ok "turn_interrupt ends the turn (it prints Interrupted)" turn_interrupt "$S"
assert_ok "…its process tree is gone" wait_until 10 bash -c "! kill -0 $fpid 2>/dev/null && ! kill -0 $gpid 2>/dev/null"
assert_ok "the runner is still up" alive "$pid"
assert_ok "…and delivers the queued nudge next" wait_until 10 bash -c "grep -qF 'after the interrupt' '$FAKE_CLAUDE_DIR/calls.jsonl'"
assert_no "the goal loop reads no reply off an interrupted turn" claude_last_reply "$WD" "$uuid"
rm -f "$FAKE_CLAUDE_DIR/hold"

echo "== harness stop leaves no lane process behind =="
assert_ok "the nudge's turn ends, the lane idle" wait_until 10 turn_is "$S" 5
rm -f "$FAKE_CLAUDE_DIR/pids"; cli_send "$S" "$WD" "hang again"
assert_ok "the last turn hangs with a grandchild" wait_until 10 test -s "$FAKE_CLAUDE_DIR/pids"
fpid=; gpid=; [[ -f "$FAKE_CLAUDE_DIR/pids" ]] && read -r fpid gpid < "$FAKE_CLAUDE_DIR/pids"
out="$(bash "$ROOT/scripts/stop.sh" 2>&1)"
assert_ok "harness stop kills the headless lane" grep -qF "killed headless $S" <<<"$out"
for p in "$pid" "$fpid" "$gpid"; do assert_no "process ${p:-?} is gone" alive "${p:-0}"; done
assert_eq "$(sess_list)" "" "no lane is listed"
assert_no "the lane is not live" sess_live "$S"
assert_eq "$(python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$S")" --field state)" ended "its state reads ended"
assert_no "sess_kill on a gone lane is false" sess_kill "$S"

echo "== the watchdog sees a headless lane's limit and transient states =="
S=hlt-main-i10; : > "$LOG"
lane i10 limit transient normal
PROMISE="ISSUE 10 DONE" MAXITER=10 GOAL=ISSUE:10 launch_agent "$S" "$WD" >/dev/null
assert_ok "the bootstrap turn hits the usage limit" wait_until 15 turn_is "$S" 1
pane="$(sess_capture "$S")"
assert_ok "the pane reads as parked at the usage limit" session_limit_idle "$pane"
assert_eq "$(limit_reset "$pane")" "12:11pm (UTC)" "…with claude's own reset time"
assert_no "…not as the transient wedge's goal-loop turn" claude_last_reply "$WD" ""
watchdog_session "$S"
assert_ok "the watchdog handles it as a limit park" grep -qF "watchdog: $S parked at its idle prompt by the usage limit" "$LOG"
assert_ok "…and its nudge is the next turn" wait_until 15 turn_is "$S" 2
assert_ok "…delivered as the limit nudge" grep -qF "the usage limit has reset" <<<"$(calls prompt | sed -n 2p)"
pane="$(sess_capture "$S")"
assert_ok "the transient turn reads as the #115 wedge" session_stalled "$pane"
assert_no "…not as a limit" session_limit_idle "$pane"
watchdog_session "$S"
assert_ok "the watchdog nudges the transient wedge" grep -qF "watchdog: $S wedged at its idle prompt after a transient API error (poll 1/3)" "$LOG"
assert_eq "$(cat "$RUN_DIR/$S.stall")" 1 "…counting the stalled poll"
assert_ok "…and the nudge runs a healthy turn" wait_until 15 turn_is "$S" 3
assert_ok "…delivered as the transient nudge" grep -qF "the transient API error has cleared" <<<"$(calls prompt | sed -n 3p)"
assert_no "the recovered lane is not stalled" session_stalled "$(sess_capture "$S")"
sess_kill "$S"; assert_no "killed" sess_live "$S"

echo "== a lane whose runner died: its pid reused by a stranger, its claude turn left running =="
S=hlt-main-i12
lane i12 hang
GOAL=ISSUE:12 launch_agent "$S" "$WD" >/dev/null
assert_ok "the bootstrap turn hangs with a grandchild" wait_until 10 test -s "$FAKE_CLAUDE_DIR/pids"
fpid=; gpid=; [[ -f "$FAKE_CLAUDE_DIR/pids" ]] && read -r fpid gpid < "$FAKE_CLAUDE_DIR/pids"
rpid="$(sess_pane_pid "$S")"
{ kill -KILL "$rpid"; wait "$rpid"; } 2>/dev/null   # the runner is this shell's child: reap it quietly
assert_no "a SIGKILLed runner's lane is not live" sess_live "$S"
assert_ok "…though its claude turn still runs (its own process group)" alive "${fpid:-0}"
sleep 600 & stranger=$!
echo "$stranger" > "$(headless_lane_dir "$S")/pid"   # the pid number now names an unrelated process
assert_no "a reused pid does not make the dead lane live" sess_live "$S"
assert_eq "$(sess_pane_pid "$S")" "" "…nor is it the lane's process id"
assert_no "sess_kill reports no live lane" sess_kill "$S"
assert_ok "…and leaves the stranger alone" alive "$stranger"
for p in "$fpid" "$gpid"; do assert_no "…but ends the turn the dead runner left (${p:-?})" alive "${p:-0}"; done
kill "$stranger" 2>/dev/null; wait "$stranger" 2>/dev/null

echo "== a CLI with no headless runner is refused as tmux-only =="
assert_ok "claude may run headless" cli_backend_check
msg="$(HARNESS_CLI=codex cli_backend_check 2>&1)"; rc=$?
assert_eq "$rc" 1 "codex on headless is refused"
assert_ok "…naming the CLI as tmux-only" grep -qF "agent CLI 'codex' is tmux-only" <<<"$msg"
assert_ok "tmux takes any CLI" env HARNESS_SESSION_BACKEND=tmux HARNESS_CLI=codex bash -c "source '$ROOT/scripts/cli/dispatch.sh'; cli_backend_check"
assert_eq "$(cli_headless_list | xargs)" claude "claude is the one CLI with a headless runner"
proj="$RUN_DIR/proj"; mkdir -p "$proj"
out="$( cd "$proj" && unset STATE_DIR && HARNESS_INIT_NONINTERACTIVE=1 HARNESS_MODE=issue-only HARNESS_TOPOLOGY=single \
  HARNESS_OWNER=acme HARNESS_REPO=acme/widget HARNESS_SESS_PREFIX=hlx HARNESS_CLI=codex bash "$ROOT/scripts/init.sh" 2>&1 </dev/null)"; rc=$?
assert_eq "$rc" 1 "harness init refuses headless + codex"
assert_ok "…naming codex as tmux-only" grep -qF "agent CLI 'codex' is tmux-only" <<<"$out"
assert_no "…and writes no config" test -f "$proj/.harness/config"
out="$(HARNESS_CLI=codex DOCTOR_FIX=0 doctor_main 2>&1)"; rc=$?
assert_ok "harness doctor flags it" grep -qF "session backend: agent CLI 'codex' is tmux-only" <<<"$out"
assert_eq "$rc" 1 "…as a problem"
out="$(cd "$proj" && STATE_DIR="$RUN_DIR/nostate" HARNESS_CLI=codex bash "$ROOT/scripts/start.sh" 2>&1)"; rc=$?
assert_no "harness start refuses it" test "$rc" -eq 0
assert_ok "…naming codex as tmux-only" grep -qF "agent CLI 'codex' is tmux-only" <<<"$out"
: > "$LOG"; lane i11 normal
( HARNESS_CLI=codex; launch_agent hlt-main-i11 "$WD" 2>/dev/null ); rc=$?
assert_eq "$rc" 1 "launch_agent with codex on headless fails"
assert_no "…starting no lane" sess_live hlt-main-i11
assert_no "…and recording no goal" test -f "$RUN_DIR/hlt-main-i11.goal"

echo "== tmux stays the default, claude's loop stays its hook there =="
assert_eq "$(HARNESS_SESSION_BACKEND=tmux claude_loop)" hook "on tmux claude's goal loop is ralph-loop's hook"
assert_eq "$(env -u HARNESS_SESSION_BACKEND bash -c "source '$ROOT/scripts/cli/dispatch.sh'; sess_backend; cli_loop")" $'tmux\nhook' "unset → tmux, hook"

echo "== docs =="
assert_ok "docs/reference.md documents the headless backend" grep -qF "### Headless lanes" "$ROOT/docs/reference.md"
for w in inbox.jsonl events.jsonl state.json "harness attach" "tmux-only"; do
  assert_ok "…naming $w" grep -qF "$w" <<<"$(sed -n '/^### Headless lanes/,/^##/p' "$ROOT/docs/reference.md")"
done
finish
