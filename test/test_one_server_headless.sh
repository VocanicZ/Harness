#!/usr/bin/env bash
# test_one_server_headless.sh — #670 / PRD #587: the headless twin of test_tmux_one_server.sh.
# On tmux every call of the backend must reach the ONE server a lane was created on, whatever TMUX the caller holds. The
# headless backend has no server: a lane is a detached runner process found by its lane directory. The equivalent is that a
# foreign TMUX in the caller's environment (a live-looking one, and a stale one) changes nothing: the lane launched under it
# is found, typed into, captured, and killed. No tmux anywhere. Only the pids this test started are signalled.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
unset HARNESS_SESSION
export RUN_DIR HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $(native_path "$FAKE")" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_STALL_RETRIES=3 HARNESS_LIMIT_NUDGE_EVERY=1 HARNESS_INTERRUPT_WAIT=10 HARNESS_HEADLESS_STOP_WAIT=10
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }
our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
not(){ ! "$@"; }
cd "$RUN_DIR" || exit 1

run_case(){ local label="$1" n="$2" sess="fleeta-main-i$2" tmuxvar="$3" wd="$RUN_DIR/wd-$2"
  echo "== $label =="
  mkdir -p "$wd" "$RUN_DIR/fake-$n"; echo "the task" > "$wd/.harness-task.md"
  echo normal > "$RUN_DIR/fake-$n/plan"
  (
    export TMUX="$tmuxvar" TMUX_PANE=%0 FAKE_CLAUDE_DIR="$RUN_DIR/fake-$n" HARNESS_SESS_PREFIX=fleeta
    GOAL="ISSUE:$n" MAXITER=10 PROMISE="ISSUE $n DONE" launch_agent "$sess" "$wd" >/dev/null 2>&1
  ); assert_eq "$?" 0 "launch_agent starts the lane"
  (
    export TMUX="$tmuxvar" TMUX_PANE=%0
    assert_ok "it is found live" sess_live "$sess"
    sess_capture "$sess" >/dev/null 2>&1; assert_eq "$?" 0 "sess_capture reads it"
    sess_type "$sess" "typed670" >/dev/null 2>&1; assert_eq "$?" 0 "sess_type reaches it"
    sess_kill "$sess" >/dev/null 2>&1
    assert_ok "sess_kill ends it" not sess_live "$sess"
  )
}
run_case "a TMUX naming a socket that exists (the analogue of a live other server)" 1 "$RUN_DIR/other.sock,1,0"
run_case "a stale TMUX (socket directory gone)" 2 "$RUN_DIR/gone-dir/default,4242,0"
finish
