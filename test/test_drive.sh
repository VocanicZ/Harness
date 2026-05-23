#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/../drive.sh"; source "$HERE/helpers.sh"
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; CAP=2; POLL=0
DISPATCHED="$RUN_DIR/dispatched"; : > "$DISPATCHED"

# stubs: no real tmux/gh. spawn_impl just records; sessions are never "live".
spawn_impl(){ echo "IMPL $1" >> "$DISPATCHED"; }
spawn_orch(){ echo "ORCH $1" >> "$DISPATCHED"; }
reap_done_sessions(){ :; }
reap_team(){ :; }
count_team_sessions(){ echo 0; }
# dispatch returns two IMPL the first tick, then nothing; unit completes on tick 2.
TICK="$RUN_DIR/tick"; echo 0 > "$TICK"
dispatch_actions(){ local n; n="$(cat "$TICK")"; n=$((n+1)); echo "$n" > "$TICK"
  if [[ "$n" == 1 ]]; then printf 'IMPL\t5\tISSUE 5 DONE\nIMPL\t6\tISSUE 6 DONE\n'; fi; }
COMPLETE_AFTER=2
unit_complete(){ [[ "$(cat "$TICK")" -ge "$COMPLETE_AFTER" ]]; }

drive_unit main
assert_eq "$(grep -c '^IMPL' "$DISPATCHED")" "2" "drove two IMPL actions on first tick"
assert_ok "loop exited when unit_complete flipped" true
finish
