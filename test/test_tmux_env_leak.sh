#!/usr/bin/env bash
# test_tmux_env_leak.sh — #547: the lane spawn that CREATES the tmux server must not leak its fleet's env into it.
# tmux copies the creating client's whole environment into the server's GLOBAL environment, so a pool worker's
# STATE_DIR / HARNESS_* / RTDD_EVENT_LOG reached every later session, whichever fleet or tool started it.
# tmux_sess_start now starts tmux from a client without those vars; the -e pairs still give the lane its own.
# Real tmux on a private TMUX_TMPDIR; kills only its own server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
command -v tmux >/dev/null || { echo "  skip: tmux not installed"; exit 0; }
# The socket path has to be short: /tmp, not a deep scratch directory.
T="$(mktemp -d /tmp/t547.XXXXXX)"
tmux_short_dir   # never the host's server (#1077: a short socket path)
trap 'tmux kill-server 2>/dev/null; rm -rf "$T"; tmp_cleanup' EXIT
LEAK='^(STATE_DIR|RTDD_EVENT_LOG|HARNESS_[A-Z0-9_]*)='

echo "== the session that creates the server leaves the global env clean =="
(
  export STATE_DIR=/fake/fleetA/.harness RTDD_EVENT_LOG=/x HARNESS_REPO=acme/a HARNESS_SESS_PREFIX=fa
  export HARNESS_CHECKOUT=/fake/co HARNESS_GUARD_BASE=/fake/base HARNESS_SNAPSHOT_FILE=/fake/snap
  source "$ROOT/scripts/session/tmux.sh"
  tmux_sess_start fa-lane-i1 /tmp -e HARNESS_SESSION=u1 -e HARNESS_PREFIX=fa -e STATE_DIR=/fake/fleetA/.harness
)
assert_eq "$(tmux show-environment -g 2>/dev/null | grep -cE "$LEAK")" 0 "no STATE_DIR / RTDD_EVENT_LOG / HARNESS_* in the server's global env"
assert_eq "$(tmux show-environment -t fa-lane-i1 HARNESS_SESSION 2>/dev/null)" "HARNESS_SESSION=u1" "the session keeps its -e HARNESS_SESSION"
assert_eq "$(tmux show-environment -t fa-lane-i1 HARNESS_PREFIX 2>/dev/null)" "HARNESS_PREFIX=fa" "…and its -e HARNESS_PREFIX"
assert_eq "$(tmux show-environment -t fa-lane-i1 STATE_DIR 2>/dev/null)" "STATE_DIR=/fake/fleetA/.harness" "…and an -e STATE_DIR"

echo "== a second session from a client without those vars does not see fleet A's =="
env -u STATE_DIR -u HARNESS_REPO tmux new-session -d -s other -c /tmp
tmux send-keys -t other "env | grep -E 'STATE_DIR|HARNESS_REPO' > $T/other.env; echo done >> $T/other.env" Enter
for _ in $(seq 30); do grep -q '^done$' "$T/other.env" 2>/dev/null && break; sleep 0.1; done
assert_eq "$(grep -v '^done$' "$T/other.env")" "" "pane env has no STATE_DIR / HARNESS_REPO"

echo "== an existing server: global env + -e pairs, unchanged =="
tmux set-environment -g SOME_GLOBAL keep
(
  export STATE_DIR=/fake/fleetB HARNESS_REPO=acme/b
  source "$ROOT/scripts/session/tmux.sh"
  tmux_sess_start fb-lane-i2 /tmp -e HARNESS_SESSION=u2 "env | grep -E '^(SOME_GLOBAL|HARNESS_SESSION|STATE_DIR)=' | sort > $T/b.env; sleep 5"
)
for _ in $(seq 30); do [[ -s $T/b.env ]] && break; sleep 0.1; done
assert_eq "$(cat "$T/b.env" 2>/dev/null)" "HARNESS_SESSION=u2
SOME_GLOBAL=keep" "the pane sees the global env plus its -e pair, and not the client's STATE_DIR"
assert_eq "$(tmux show-environment -g 2>/dev/null | grep -cE "$LEAK")" 0 "global env still clean"

echo "== #558: tmux_sess_start leaves the caller's scope alone =="
# A temporary (`VAR=x f`) or `local` value must not come back as an exported global; a `tmux` FUNCTION stub
# still runs in this shell and keeps its side effects. Measured in a subshell, asserted out here.
R="$T/scope.out"
(
  source "$ROOT/scripts/session/tmux.sh"
  STUB_LOG="$T/stub.log"; : > "$STUB_LOG"
  tmux(){ echo "$*" >> "$STUB_LOG"; STUB_RAN=yes; }
  f(){ tmux_sess_start s558 /tmp; }
  export HARNESS_CLI=claude
  HARNESS_CLI=agy f
  echo "temp=$HARNESS_CLI"
  echo "child=$(bash -c 'echo "$HARNESS_CLI"')"
  unset HARNESS_CLI
  HARNESS_CLI=agy f
  echo "unset=${HARNESS_CLI-unset}"
  export STATE_DIR=/global/state
  g(){ local STATE_DIR=/local/state; tmux_sess_start s558 /tmp; }
  g
  echo "local=$STATE_DIR"
  echo "stub=${STUB_RAN-}"
) > "$R"
assert_eq "$(grep '^temp=' "$R")" "temp=claude" "a temporary HARNESS_CLI=agy does not outlive the call"
assert_eq "$(grep '^child=' "$R")" "child=claude" "…and a child process sees the earlier value"
assert_eq "$(grep '^unset=' "$R")" "unset=unset" "a HARNESS_* that was unset before stays unset"
assert_eq "$(grep '^local=' "$R")" "local=/global/state" "a caller's local STATE_DIR does not change the global one"
assert_eq "$(grep '^stub=' "$R")" "stub=yes" "a tmux function stub still runs in the current shell (side effects kept)"
assert_eq "$(head -n1 "$T/stub.log")" "new-session -d -s s558 -c /tmp" "…and gets the new-session args"

echo "== TMUX_TMPDIR is honoured =="
assert_ok "the server socket is under the private TMUX_TMPDIR" bash -c 'ls "$1"/tmux-*/default >/dev/null 2>&1' _ "$TMUX_TMPDIR"

finish
