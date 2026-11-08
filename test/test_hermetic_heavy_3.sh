#!/usr/bin/env bash
# test_hermetic_heavy_3.sh — heavy slice 3 of 3 of the generalised decoy of test_hermetic.sh (#608: split out of it, so each file finishes under the per-test
# cap on Windows): a LIVE worker in a registered fleet must survive every test that updates, supervises or starts a fleet.# that updates, supervises, or starts a fleet — handed ONLY the fleet/poller/snapshot pins, which is all a
# lane inherits of the real host. The decoy is the incident in miniature: a registered fleet whose worker
# runs a foreign ENGINE_DIR, which fleet_roll kills and relaunches from the sandbox engine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/hermetic_lib.sh"
# #610: every bare mktemp below lands in one private dir that goes with the test, so a run from a plain
# shell (not run.sh, which gives each test its own TMPDIR) leaves /tmp as it found it.
PRIVATE_TMP="$(mktemp -d)"; tmp_track "$PRIVATE_TMP"; export TMPDIR="$PRIVATE_TMP"
unset_inherited_config   # a direct run from inside a live lane (#541): its HARNESS_* config must not reach the probes below

hermetic_scan; mine=(); while read -r x; do [[ -n $x ]] && mine+=("$x"); done < <(hermetic_slice 3 3 ${heavy_tests[@]+"${heavy_tests[@]}"})
echo "-- heavy slice 3 of 3: ${mine[*]:-nothing}"
DECOY_PID=""
for t in ${mine[@]+"${mine[@]}"}; do
  make_live_fleet
  # Only the fleet/poller/snapshot pins reach the test — and a PRIVATE tmux server, never the lane's identity
  # (STATE_DIR, HARNESS_SESSION, TMUX…): the decoy guards the registry, it must not hand a test the lane's own
  # session to sweep (#541, the lane ran this block and died with 137).
  env -u STATE_DIR -u HARNESS_SESSION -u HARNESS_ISSUE -u HARNESS_PRD -u HARNESS_KIND -u HARNESS_PREFIX -u TMUX -u TMUX_PANE \
      TMUX_TMPDIR="$(mktemp -d)" HARNESS_FLEETS_DIR="$LIVE_ROOT/fleets" HARNESS_POLLER_DIR="$LIVE_ROOT/poller" \
      HARNESS_SNAPSHOTS_DIR="$LIVE_ROOT/snapshots" bash "$HERE/$t" >/dev/null 2>&1
  assert_ok "$t: the registered fleet's live worker is not killed" kill -0 "$DECOY_PID"
  assert_eq "$(ls "$LIVE_ROOT/fleets")" "decoy.json" "$t: the fleet registry holds only its one original entry"
  assert_eq "$(ls "$LIVE_ROOT/decoy/proj/.harness/run")" "worker-1.pid" "$t: no worker / priority pid file was relaunched into the live fleet"
  assert_eq "$(find "$LIVE_ROOT/poller/registry" "$LIVE_ROOT/snapshots" -mindepth 1 | wc -l)" "0" "$t: nothing in the live poller registry or snapshots dir"
  kill "$DECOY_PID" 2>/dev/null; wait "$DECOY_PID" 2>/dev/null
done

finish
