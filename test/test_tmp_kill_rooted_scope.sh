#!/usr/bin/env bash
# test_tmp_kill_rooted_scope.sh — #649: tmp_cleanup / tmp_kill_rooted stop processes by the dirs a test tracked. A tracked dir that is
# broad (shallow, $HOME, or containing $HOME or the host's real ~/.harness) must never sweep up the user's live workers and lanes.
#   1. a process rooted in a tracked throwaway dir is stopped (the #419 behaviour stays)
#   2. a process rooted under $HOME / the host ~/.harness survives tmp_kill_rooted of $HOME, of /, of /home, and of a dir holding $HOME
# The "live worker" is a stand-in sleep with its own cwd/STATE_DIR under a fake HOME. No real worker is touched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
FH="$ROOT/home/claude"; mkdir -p "$FH/.harness/state" "$ROOT/throwaway/a"
export HOME="$FH"
P=()
spawn_cwd(){ ( cd "$1" && exec nohup sleep 120 >/dev/null 2>&1 9>&- ) & P+=($!); }
spawn_state(){ ( cd / && STATE_DIR="$1" exec nohup sleep 120 >/dev/null 2>&1 9>&- ) & P+=($!); }
cleanup(){ local p; for p in "${P[@]}"; do [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )) && kill "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
alive(){ kill -0 "$1" 2>/dev/null && [[ "$(awk '/^State:/{print $2}' /proc/$1/status 2>/dev/null)" != Z ]]; }

spawn_cwd "$ROOT/throwaway/a"; T1=${P[0]}
spawn_cwd "$FH/.harness/state"; L1=${P[1]}
spawn_state "$FH/.harness/state"; L2=${P[2]}
sleep 0.3
echo "=== 1. a process rooted in a throwaway tracked dir is stopped ==="
tmp_kill_rooted "$ROOT/throwaway"
sleep 0.3
assert_no "the stand-in rooted in the throwaway dir is gone" alive "$T1"
assert_ok "...and the 'live' ones were not touched" bash -c "kill -0 $L1 && kill -0 $L2"
echo "=== 2. a broad root never sweeps up live workers ==="
for root in "$FH" "$FH/.harness" "$ROOT/home" "$ROOT" / /home /tmp; do
  tmp_kill_rooted "$root"; sleep 0.2
  assert_ok "tmp_kill_rooted $([[ $root == "$ROOT"* ]] && echo "<root>${root#$ROOT}" || echo "$root") leaves the live stand-ins running" bash -c "kill -0 $L1 && kill -0 $L2"
done
finish
