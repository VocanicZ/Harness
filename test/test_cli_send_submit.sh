#!/usr/bin/env bash
# test_cli_send_submit.sh — #1201: a line injected into a tmux lane is typed, left to land, then submitted with Enter, and the pane is
# read back: an Enter swallowed as part of a paste leaves the text on the input line, so it is re-sent, and a send that never
# submitted fails (inject_unsubmitted) instead of looking delivered — _wait_deliver then keeps the wake line and retries it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
export HARNESS_SESSION_BACKEND=tmux HARNESS_CLI=claude
source "$HERE/../scripts/wait.sh"
TLOG="$RUN_DIR/tmux.log"; PANEF="$RUN_DIR/pane"
# The stub tmux logs its calls; `capture-pane` answers from $PANEF, a script of panes: the first line of $PANEF.n is how many
# Enters the pane has seen, and PANE_MODE says what the pane shows then (stuck = the text stays on the prompt, clears_after_N).
tmux(){ local ec; echo "tmux $*" >> "$TLOG"
  case "$1" in
    capture-pane) cat "$PANEF" 2>/dev/null;;
    send-keys) [[ " $* " == *" Enter "* ]] && { ec=$(( $(cat "$PANEF.n" 2>/dev/null || echo 0) + 1 )); echo "$ec" > "$PANEF.n"
        [[ $PANE_MODE == stuck ]] || printf 'old reply\n❯ \n' > "$PANEF"; };;
  esac; return 0; }
sleep(){ echo "sleep $*" >> "$TLOG"; }
reset(){ : > "$TLOG"; rm -f "$PANEF" "$PANEF.n"; unset HARNESS_SEND_ENTER_DELAY_S HARNESS_SEND_RETRY_S; }
enters(){ grep -c 'send-keys -t sess-x Enter' "$TLOG"; }
TEXT="Please resume: your Round 1 run finished, rc=0"

echo "=== the Enter waits for the text to land ==="
reset; PANE_MODE=ok; printf 'old reply\n❯ %s\n' "$TEXT" > "$PANEF"
cli_send sess-x "" "$TEXT"; rc=$?
assert_eq "$(grep -v capture-pane "$TLOG")" $'tmux send-keys -t sess-x -l '"$TEXT"$'\nsleep 0.5\ntmux send-keys -t sess-x Enter' \
  "claude: type, a 0.5 s pause, then Enter"
assert_eq "$rc" 0 "…a line that left the input box is delivered (rc 0)"
assert_eq "$(enters)" 1 "…with exactly one Enter"
reset; PANE_MODE=ok; export HARNESS_SEND_ENTER_DELAY_S=2
cli_send sess-x "" "$TEXT"
assert_ok "HARNESS_SEND_ENTER_DELAY_S sets the pause" grep -qx 'sleep 2' "$TLOG"
reset; PANE_MODE=ok; export HARNESS_SEND_ENTER_DELAY_S=0
cli_send sess-x "" "$TEXT"
assert_no "…0 removes the wait" grep -q '^sleep' "$TLOG"

echo "=== a swallowed Enter is re-sent, then the send fails ==="
reset; PANE_MODE=stuck; printf 'old reply\n❯ %s\n' "$TEXT" > "$PANEF"
cli_send sess-x "" "$TEXT" 2>"$RUN_DIR/err"; rc=$?
assert_eq "$(enters)" 4 "the text still on the prompt: Enter re-sent 3 times (4 in all)"
assert_ok "…after a pause each time" grep -qx 'sleep 3' "$TLOG"
assert_eq "$rc" 1 "…and cli_send fails"
assert_ok "…naming inject_unsubmitted and the session" grep -q 'inject_unsubmitted.*sess-x' "$RUN_DIR/err"
reset; PANE_MODE=stuck; printf 'old reply\n❯ %s\n' "$TEXT" > "$PANEF"
reset; PANE_MODE=stuck; export HARNESS_SEND_RETRY_S=1; printf 'old reply\n❯ %s\n' "$TEXT" > "$PANEF"
cli_send sess-x "" "$TEXT" 2>/dev/null
assert_ok "HARNESS_SEND_RETRY_S sets the retry pause" grep -qx 'sleep 1' "$TLOG"

echo "=== the Enter that submits on a retry ==="
reset; PANE_MODE=stuck; printf '❯ %s\n' "$TEXT" > "$PANEF"
tmux(){ local ec; echo "tmux $*" >> "$TLOG"
  case "$1" in capture-pane) cat "$PANEF";;
    send-keys) [[ " $* " == *" Enter "* ]] && { ec=$(( $(cat "$PANEF.n" 2>/dev/null || echo 0) + 1 )); echo "$ec" > "$PANEF.n"
        (( ec >= 2 )) && printf '❯ \n' > "$PANEF"; };; esac; return 0; }
cli_send sess-x "" "$TEXT"; rc=$?
assert_eq "$(enters)" 2 "a second Enter that clears the prompt stops the retries"
assert_eq "$rc" 0 "…and the send is delivered"

echo "=== a short prefix, robust to wrapping ==="
reset; PANE_MODE=stuck; LONG="$(printf 'word%02d ' $(seq 1 40))"
printf '❯ %s\nword11 word12\n' "${LONG:0:60}" > "$PANEF"
tmux(){ echo "tmux $*" >> "$TLOG"; [[ $1 == capture-pane ]] && cat "$PANEF"; return 0; }
cli_send sess-x "" "$LONG" 2>/dev/null; rc=$?
assert_eq "$rc" 1 "a long line wrapped on the pane is still seen on the prompt by its first characters"

echo "=== empty capture = submitted ==="
reset; : > "$PANEF"; tmux(){ echo "tmux $*" >> "$TLOG"; return 0; }
cli_send sess-x "" "$TEXT"; rc=$?
assert_eq "$rc" 0 "a pane that cannot be read does not fail the send"
assert_eq "$(enters)" 1 "…and costs no retry"

echo "=== _wait_deliver keeps the wake line when the send failed ==="
reset; PANE_MODE=stuck; printf '❯ %s\n' "$TEXT" > "$PANEF"
tmux(){ echo "tmux $*" >> "$TLOG"; [[ $1 == capture-pane ]] && cat "$PANEF"; return 0; }
echo "$TEXT" > "$RUN_DIR/sess-x.wait.msg"
_wait_deliver sess-x 2>/dev/null; rc=$?
assert_eq "$rc" 1 "an unsubmitted wake line fails _wait_deliver"
assert_ok "…and stays on disk for the next tick" test -s "$RUN_DIR/sess-x.wait.msg"
printf '❯ \n' > "$PANEF"
_wait_deliver sess-x; rc=$?
assert_eq "$rc" 0 "the next tick delivers it"
assert_no "…and removes it" test -e "$RUN_DIR/sess-x.wait.msg"

echo "=== one send path ==="
assert_no "supervise's nudge has no inline type/sleep/Enter copy" grep -qE 'sleep 0\.5' "$HERE/../scripts/supervise.sh"
assert_ok "…it goes through cli_send_typed" grep -q 'cli_send_typed' "$HERE/../scripts/supervise.sh"
assert_ok "hermes_send goes through cli_send_typed" grep -q 'cli_send_typed' "$HERE/../scripts/cli/hermes.sh"
finish
