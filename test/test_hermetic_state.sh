#!/usr/bin/env bash
# test_hermetic_state.sh — the first two seams of test_hermetic.sh (#608: split out of it, so each file finishes under the per-test cap on
# Windows): a test run with an inherited STATE_DIR / HARNESS_POLLER_DIR must leave a decoy "live project" and a decoy host root untouched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/hermetic_lib.sh"
# #610: every bare mktemp below lands in one private dir that goes with the test, so a run from a plain
# shell (not run.sh, which gives each test its own TMPDIR) leaves /tmp as it found it.
PRIVATE_TMP="$(mktemp -d)"; tmp_track "$PRIVATE_TMP"; export TMPDIR="$PRIVATE_TMP"
unset_inherited_config   # a direct run from inside a live lane (#541): its HARNESS_* config must not reach the probes below

# The offenders: init.sh writes $STATE_DIR/config; drive/bug_flow build $STATE_DIR/worktrees paths.
for t in test_init.sh test_bug_flow.sh test_drive.sh; do
  [[ -f "$HERE/$t" ]] || continue
  decoy="$(make_decoy)"
  STATE_DIR="$decoy" bash "$HERE/$t" >/dev/null 2>&1
  assert_untouched "$decoy" "$t"
done

# ── the HOST root (lib.sh:86-92) is a second, independent seam ──────────────────────────────────
# HARNESS_HOME is NOT derived from STATE_DIR, so pinning STATE_DIR alone left the real ~/.harness
# poller registry writable. That registry is SHARED by every co-resident fleet and `harness start`
# aborts on a prefix collision against it, so fixture entries there don't merely litter — they stop
# an unrelated production fleet from starting at all.
# The vector is HARNESS_POLLER_DIR specifically, not HARNESS_HOME: lib.sh:87 prefers an INHERITED
# HARNESS_POLLER_DIR over the HARNESS_HOME a test just set, and :89 exports it from every fleet
# process — so test_prefix_guard.sh's own `export HARNESS_HOME="$(mktemp -d)"` (line 8) is defeated
# exactly the way test_init.sh's `export HARNESS_DIR` was.

for t in test_prefix_guard.sh test_poller.sh test_priority.sh test_worker.sh; do
  [[ -f "$HERE/$t" ]] || continue
  host="$(make_host_decoy)"
  HARNESS_POLLER_DIR="$host/poller" HARNESS_SNAPSHOTS_DIR="$host/snapshots" bash "$HERE/$t" >/dev/null 2>&1
  assert_eq "$(find "$host/poller/registry" -mindepth 1 | wc -l)" "0" "$t: no registry entries in live host root"
  assert_eq "$(find "$host/snapshots" -mindepth 1 | wc -l)" "0" "$t: no snapshots in live host root"
done

finish
