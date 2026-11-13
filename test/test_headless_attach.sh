#!/usr/bin/env bash
# test_headless_attach.sh — #487 / PRD #475 task 3: `harness attach <lane>` drives a headless lane. A line
# typed into the attach lands in the lane's inbox through cli_send and runs as the next turn — queued
# behind a turn that is still running — and Ctrl-C (SIGINT to the attach process) detaches: the attach
# exits, the lane's runner stays alive and its state is unchanged. The fake claude of the runner's
# fixtures stands in for the CLI (test/fixtures/cli/claude/stream-json/).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
export RUN_DIR HARNESS_SESS_PREFIX=hat HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
# The runner starts the fake with CreateProcess on Windows, which cannot run python3 there (an sh shim): `python`.
# …and from a path it understands (C:/…), not Git Bash's /c/….
PYBIN=python3; is_windows && { PYBIN=python; FAKE="$(cygpath -m "$FAKE")"; }
export HARNESS_CLAUDE_BIN="$PYBIN $FAKE" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_INTERRUPT_WAIT=10
HL="$ROOT/scripts/cli/claude_headless.py"

# Only the processes this test started: the lane's runner (its pid file), each fake claude (calls.jsonl)
# and the attach (its pid). Never a pattern kill: the host runs other lanes.
cleanup(){ local d p; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do p="$(cat "$d/pid" 2>/dev/null)"; [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done
  for d in "$RUN_DIR"/fake-*/; do
    for p in $(python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null); do
      kill -KILL "$p" 2>/dev/null
    done
  done
  [[ ${APID:-} =~ ^[0-9]+$ ]] && kill -KILL "$APID" 2>/dev/null
  exec 7<&- 2>/dev/null; shopt -u nullglob; tmp_cleanup; }
trap cleanup EXIT
alive(){ proc_alive "$1"; }
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
calls(){ python3 -c 'import json,sys; [print(json.dumps(json.loads(l)[sys.argv[2]])) for l in open(sys.argv[1])]' \
  "$FAKE_CLAUDE_DIR/calls.jsonl" "$1" 2>/dev/null; }
lane_state(){ python3 "$HL" state --lane "$(headless_lane_dir "$S")" --field state; }
lane_state_is(){ [[ "$(lane_state)" == "$1" ]]; }   # polled: `wait_until … test "$(lane_state)" = x` reads once, before it waits (#606)
turn_is(){ [[ "$(python3 "$HL" state --lane "$(headless_lane_dir "$S")" --field turn)" == "$1" && "$(lane_state)" == idle ]]; }
out_has(){ grep -qF -- "$1" "$OUT" 2>/dev/null; }

S=hat-main-i1
WD="$RUN_DIR/wd"; mkdir -p "$WD"; echo "the task" > "$WD/.harness-task.md"
export FAKE_CLAUDE_DIR="$RUN_DIR/fake"; mkdir -p "$FAKE_CLAUDE_DIR"
printf '%s\n' normal "normal answer to the typed line" normal > "$FAKE_CLAUDE_DIR/plan"
touch "$FAKE_CLAUDE_DIR/hold"   # the bootstrap turn waits mid-turn until released
launch_out="$(PROMISE="ISSUE 1 DONE" MAXITER=10 GOAL=ISSUE:1 launch_agent "$S" "$WD" 2>&1)"; launch_rc=$?
assert_eq "$launch_rc" 0 "launch_agent starts the lane${launch_out:+ ($launch_out)}"
assert_ok "the lane is live" sess_live "$S"
RUNNER="$(sess_pane_pid "$S")"
assert_ok "the bootstrap turn is running" wait_until 10 lane_state_is busy
INBOX="$(headless_lane_dir "$S")/inbox.jsonl"
BEFORE_INBOX="$(wc -l < "$INBOX")"

echo "== attach: typed lines reach the inbox, queued behind the running turn =="
OUT="$RUN_DIR/attach.out"; : > "$OUT"
mkfifo "$RUN_DIR/attach.in"; exec 7<>"$RUN_DIR/attach.in"
# The attach must start with SIGINT at its default (#553). Job control (set -m) gives the background attach
# its own process group, but a SIGINT that was ignored when this test started stays ignored in it and
# in every child (bash cannot trap what it inherited ignored) — and the suite runs that way from the
# auto-release gate, a background job. So restore the default through DEFSIG instead.
# HAT_ATTACH_IGNORE_INT=1 simulates an attach that really cannot take a SIGINT (test_signal_defaults.sh).
default_signals_prefix
SIGINT_OK=1; sigint_restorable || SIGINT_OK=0
ATTACH_WRAP=(); [[ -n "${HAT_ATTACH_IGNORE_INT:-}" ]] && ATTACH_WRAP=(env --ignore-signal=INT)
set -m
"${DEFSIG[@]}" ${ATTACH_WRAP[@]+"${ATTACH_WRAP[@]}"} bash "$ROOT/scripts/attach.sh" "$S" <&7 >"$OUT" 2>&1 &
APID=$!
assert_ok "attach is watching the lane" wait_until 10 out_has "watching headless lane $S"
assert_ok "…and shows the running turn" wait_until 10 out_has "── turn 1 (bootstrap)"
printf '\n   \n' >&7   # blank lines are not messages
printf 'please do the typed thing\n' >&7
assert_ok "attach says the line is queued behind the running turn" wait_until 10 out_has "· queued behind the running turn: please do the typed thing"
assert_ok "the line landed in the lane's inbox" wait_until 10 grep -qF '"text": "please do the typed thing"' "$INBOX"
assert_eq "$(( $(wc -l < "$INBOX") - BEFORE_INBOX ))" 1 "…as exactly one message (blank lines sent nothing)"
assert_eq "$(calls prompt | wc -l)" 1 "it has not run yet: the bootstrap turn still holds the lane"
rm -f "$FAKE_CLAUDE_DIR/hold"
assert_ok "both turns run, and the lane reads idle" wait_until 15 turn_is 2
assert_eq "$(calls prompt | sed -n 2p)" '"please do the typed thing"' "the typed line ran as the next turn"
assert_ok "…resumed on the lane's session" grep -qF '"--resume"' <<<"$(calls argv | sed -n 2p)"
assert_ok "attach shows that turn" wait_until 10 out_has "── turn 2 (message) ── please do the typed thing"
assert_ok "…and its reply" wait_until 10 out_has "← answer to the typed line"

echo "== attach: an idle lane takes the line as sent, not queued =="
printf 'one more\n' >&7
assert_ok "attach says it sent it" wait_until 10 out_has "· sent: one more"
assert_ok "…and it runs as turn 3" wait_until 15 turn_is 3
assert_eq "$(calls prompt | sed -n 3p)" '"one more"' "the third prompt is the typed line"

echo "== attach: a line with invalid UTF-8 is delivered with replacement characters, never dropped (#1126) =="
BEFORE_BAD="$(wc -l < "$INBOX")"
printf 'bad\377byte\n' >&7
assert_ok "attach confirms it only after the send, once it is in the inbox" wait_until 10 out_has "· sent: bad"
assert_eq "$(( $(wc -l < "$INBOX") - BEFORE_BAD ))" 1 "…one more message on the inbox"
assert_eq "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1], encoding="utf-8").read().splitlines()[-1])["text"] == "bad\ufffdbyte")' "$INBOX")" True "…the bad byte arrives as a replacement character"
assert_ok "…and it runs as turn 4" wait_until 15 turn_is 4

echo "== attach: Ctrl-C detaches and leaves the lane running =="
STATE_BEFORE="$(cat "$(headless_lane_dir "$S")/state.json")"
gone(){ ! proc_alive "$1"; }
if (( SIGINT_OK )); then
  kill -INT "$APID"
  assert_ok "the attach process exits" wait_until 10 gone "$APID"
else
  echo "  SKIP: Ctrl-C itself — this host cannot restore SIGINT for a child of a shell that ignores it; detaching with SIGTERM, which the attach traps the same way"
  kill -TERM "$APID"
  assert_ok "the attach process exits" wait_until 10 gone "$APID"
fi
# Never an unbounded wait on a process that may still be alive: a failed detach must end this test, not hang it.
# Only the attach this test started ($APID), TERM first, then KILL.
if ! gone "$APID"; then
  kill -TERM "$APID" 2>/dev/null; wait_until 5 gone "$APID" || { kill -KILL "$APID" 2>/dev/null; wait_until 5 gone "$APID"; }
fi
assert_ok "…and no attach is left alive" gone "$APID"
wait "$APID"; rc=$?
assert_eq "$rc" 0 "…cleanly"
assert_ok "it says it detached" grep -qF "detached; headless lane $S keeps running" "$OUT"
assert_ok "the lane's runner is still alive" alive "$RUNNER"
assert_eq "$(sess_pane_pid "$S")" "$RUNNER" "…the same runner, still the lane's"
assert_ok "the lane is still live" sess_live "$S"
assert_eq "$(lane_state)" idle "its state is still idle"
assert_eq "$(cat "$(headless_lane_dir "$S")/state.json")" "$STATE_BEFORE" "…and state.json is byte for byte unchanged"
assert_eq "$(calls prompt | wc -l)" 4 "detaching sent nothing to the lane"
if command -v pgrep >/dev/null 2>&1; then
  assert_no "the watch it started is gone" pgrep -f "claude_headless.py watch --lane $(headless_lane_dir "$S")"
fi
exec 7<&-

echo "== attach: a lane that is not live is refused =="
out="$(bash "$ROOT/scripts/attach.sh" hat-main-i99 2>&1 </dev/null)"; rc=$?
assert_eq "$rc" 1 "attach to no lane fails"
assert_ok "…naming it" grep -qF "no live" <<<"$out"
# #1123: the error is on stderr, not stdout — capture the two streams apart.
bash "$ROOT/scripts/attach.sh" hat-main-i99 >"$RUN_DIR/refuse.out" 2>"$RUN_DIR/refuse.err" </dev/null; rc=$?
assert_eq "$rc" 1 "attach to no lane fails (streams captured apart)"
assert_ok "…the error is on stderr" grep -qF "no live session '" "$RUN_DIR/refuse.err"
assert_eq "$(cat "$RUN_DIR/refuse.out")" "" "…and stdout stays empty"

echo "== attach: a failed send prints no confirmation, names the line on stderr, and attach goes on (#1126) =="
(  # stubs: a lane whose send fails, then one whose send works
  cli_send(){ return 1; }; _hl_state(){ echo idle; }; headless_lane_dir(){ echo "$RUN_DIR/nolane"; }
  _hl_attach_send "$S" "lost line" >"$RUN_DIR/fs.out" 2>"$RUN_DIR/fs.err"; echo $? > "$RUN_DIR/fs.rc"
  cli_send(){ return 0; }
  _hl_attach_send "$S" "good line" >"$RUN_DIR/ok.out" 2>"$RUN_DIR/ok.err" )
assert_eq "$(cat "$RUN_DIR/fs.rc")" 0 "a failed send does not end the attach"
assert_eq "$(cat "$RUN_DIR/fs.out")" "" "…nothing is confirmed on stdout"
assert_ok "…stderr names the line" grep -qF "lost line" "$RUN_DIR/fs.err"
assert_eq "$(cat "$RUN_DIR/ok.out")" "· sent: good line" "…and a send that works is confirmed after it"
assert_eq "$(cat "$RUN_DIR/ok.err")" "" "…with nothing on stderr"

echo "== attach: with stdin closed it is still the live watch =="
WAIT=3; is_windows && WAIT=20   # Git Bash takes seconds to start a script
out="$(timeout "$WAIT" bash "$ROOT/scripts/attach.sh" "$S" 2>&1 </dev/null)"
assert_ok "it watches the lane" grep -qF "watching headless lane $S" <<<"$out"
assert_ok "…showing the typed line's turn" grep -qF "── turn 2 (message) ── please do the typed thing" <<<"$out"
assert_eq "$(calls prompt | wc -l)" 4 "…and typed nothing"
finish
