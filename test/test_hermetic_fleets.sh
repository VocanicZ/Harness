#!/usr/bin/env bash
# test_hermetic_fleets.sh — the third seam of test_hermetic.sh (#608: split out of it): the host FLEET registry.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/hermetic_lib.sh"
# #610: every bare mktemp below lands in one private dir that goes with the test, so a run from a plain
# shell (not run.sh, which gives each test its own TMPDIR) leaves /tmp as it found it.
PRIVATE_TMP="$(mktemp -d)"; tmp_track "$PRIVATE_TMP"; export TMPDIR="$PRIVATE_TMP"
unset_inherited_config   # a direct run from inside a live lane (#541): its HARNESS_* config must not reach the probes below

# ── the host FLEET registry is a THIRD such seam, and the worst of the three ────────────────────
# lib.sh:99-100 prefers an inherited HARNESS_FLEETS_DIR over the HARNESS_HOME a test sets for itself
# and then exports it, so every fleet worker hands ~/.harness/fleets down to the agent session that
# runs this suite. Unlike the poller registry, entries here are not merely read — `doctor --fix`
# DELETES them (test_doctor.sh calls doctor_main --fix), so the suite could strip a live sibling
# fleet's prefix reservation off the real host. The decoy holds one entry and must come back intact.
make_fleet_decoy(){ local d; d="$(mktemp -d)/.harness"; mkdir -p "$d/fleets"
  printf '%s\n' '{"prefix":"live","project":"/live/proj/.harness","run_dir":"/live/proj/.harness/run","slugs":["live/repo"],"started_at":0}' \
    > "$d/fleets/live.json"; printf '%s' "$d"; }
for t in test_doctor.sh test_prefix_guard.sh test_fleet_registry.sh test_init.sh test_status.sh; do
  [[ -f "$HERE/$t" ]] || continue
  host="$(make_fleet_decoy)"
  HARNESS_FLEETS_DIR="$host/fleets" bash "$HERE/$t" >/dev/null 2>&1
  assert_ok "$t: the live fleet-registry entry survives (not pruned by --fix)" \
    test -f "$host/fleets/live.json"
  assert_eq "$(find "$host/fleets" -mindepth 1 | wc -l)" "1" "$t: no fixture entries in the live fleet registry"
done

finish
