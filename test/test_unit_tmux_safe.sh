#!/usr/bin/env bash
# test_unit_tmux_safe.sh — #554: HARNESS_UNIT goes into tmux session names (<prefix>-<unit>-i<N>), and tmux
# reads `.` and `:` in a target as window/pane separators — `has-session -t hz-next.js-i5` is "can't find pane"
# although new-session made hz-next_js-i5. fleet_unit (lib.sh) maps every character outside [A-Za-z0-9_-] to `_`,
# so every reader agrees, and a unit that is already safe is returned unchanged (session names of live fleets).
# Real tmux on a private TMUX_TMPDIR; kills only its own server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
make_env
source "$ROOT/scripts/lib.sh" >/dev/null 2>&1

echo "== fleet_unit: an unsafe HARNESS_UNIT is normalised, a safe one is untouched =="
unit_of(){ ( HARNESS_UNIT="$1"; fleet_unit ); }
assert_eq "$(unit_of next.js)"          "next_js"          "next.js -> next_js"
assert_eq "$(unit_of owner.github.io)"  "owner_github_io"  "owner.github.io -> owner_github_io"
assert_eq "$(unit_of 'a:b')"            "a_b"              "a colon -> _"
assert_eq "$(unit_of 'a b')"            "a_b"              "a space -> _"
assert_eq "$(unit_of harness)"          "harness"          "harness unchanged"
assert_eq "$(unit_of main)"             "main"             "main unchanged"
assert_eq "$(unit_of my-repo_2)"        "my-repo_2"        "dash, underscore and digit unchanged"
assert_eq "$(unit_of Mixed-Case)"       "Mixed-Case"       "an already-safe unit with capitals unchanged"
assert_eq "$(unit_of '')"               "main"             "empty -> main"
assert_eq "$(unit_of '..')"             "__"               "dots only -> underscores"
assert_eq "$( ( unset HARNESS_UNIT; fleet_unit ) )" "main" "unset -> main"
assert_eq "$(unit_safe 'x.y')"          "x_y"              "unit_safe is the one rule"
HARNESS_UNIT=next.js HARNESS_SESS_PREFIX=hz
assert_eq "$(sess_impl "$(fleet_unit)" 5)" "hz-next_js-i5" "sess_impl on the dotted unit has no dot"

command -v tmux >/dev/null || { echo "  skip: tmux not installed"; finish; exit 0; }
echo "== a lane session for a dotted repo is found live =="
T="$(mktemp -d /tmp/t554.XXXXXX)"   # the socket path has to be short
export TMUX_TMPDIR="$T"; unset TMUX TMUX_PANE   # never the host's server
trap 'tmux kill-server 2>/dev/null; rm -rf "$T"' EXIT
export HARNESS_SESSION_BACKEND=tmux
HARNESS_REPO=vercel/next.js HARNESS_UNIT=next.js HARNESS_SESS_PREFIX=hz
S="$(sess_impl "$(fleet_unit)" 5)"
assert_no "no dot or colon in the session name" bash -c '[[ "$1" == *[.:]* ]]' _ "$S"
sess_start "$S" /tmp >/dev/null 2>&1
assert_ok "session_live reports the lane live" session_live "$S"
assert_ok "team_sessions lists it" bash -c 'source "$1/scripts/lib.sh" >/dev/null 2>&1; HARNESS_UNIT=next.js HARNESS_SESS_PREFIX=hz; team_sessions "$(fleet_unit)" | grep -qx hz-next_js-i5' _ "$ROOT"
assert_eq "$(session_lane_key "$S")" "impl-5" "session_lane_key reads the lane number back"
# the bug this fixes: the RAW unit never finds the session tmux created
assert_no "(control) the raw dotted name is not found" session_live "hz-next.js-i5"

finish
