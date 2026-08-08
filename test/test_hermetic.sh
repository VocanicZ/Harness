#!/usr/bin/env bash
# test_hermetic.sh — the suite must never write a LIVE project's state.
#
# lib.sh honours an inherited STATE_DIR (scripts/lib.sh:15) and exports it (:16), and every pool
# worker exports its project's STATE_DIR to every child — including the agent sessions that run
# this suite. So a test run from inside a live fleet used to resolve CONFIG / WORKTREES_DIR /
# CHECKOUTS_DIR to that fleet's real .harness/ and scribble on it: `harness init`'s acme/widget
# config landed on top of a production config, and bug-acme_widget-i42 worktrees appeared in a
# real project's worktrees dir.
#
# This test pins STATE_DIR at a decoy "live project" and runs the three tests that did the damage.
# The decoy must come back untouched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

SENTINEL=': "${HARNESS_REPO:=sentinel/live}"'

# make_decoy — a plausible live project state dir, echoed on stdout.
make_decoy(){
  local d; d="$(mktemp -d)/.harness"
  mkdir -p "$d/worktrees" "$d/checkouts" "$d/run/claims"
  printf '%s\n' "$SENTINEL" > "$d/config"
  printf '%s' "$d"
}

# assert_untouched <decoy> <label> — config still the sentinel, no worktrees/checkouts created.
assert_untouched(){
  local d="$1" label="$2"
  assert_eq "$(cat "$d/config")" "$SENTINEL" "$label: live config not overwritten"
  assert_eq "$(find "$d/worktrees" -mindepth 1 | wc -l)" "0" "$label: no worktrees in live state dir"
  assert_eq "$(find "$d/checkouts" -mindepth 1 | wc -l)" "0" "$label: no checkouts in live state dir"
}

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
make_host_decoy(){ local d; d="$(mktemp -d)/.harness"; mkdir -p "$d/poller/registry" "$d/snapshots"; printf '%s' "$d"; }
for t in test_prefix_guard.sh test_poller.sh test_priority.sh test_worker.sh; do
  [[ -f "$HERE/$t" ]] || continue
  host="$(make_host_decoy)"
  HARNESS_POLLER_DIR="$host/poller" HARNESS_SNAPSHOTS_DIR="$host/snapshots" bash "$HERE/$t" >/dev/null 2>&1
  assert_eq "$(find "$host/poller/registry" -mindepth 1 | wc -l)" "0" "$t: no registry entries in live host root"
  assert_eq "$(find "$host/snapshots" -mindepth 1 | wc -l)" "0" "$t: no snapshots in live host root"
done

# A test that calls make_env must also be hermetic when run directly with a live STATE_DIR
# exported — make_env re-pins STATE_DIR and everything lib.sh derived from it.
decoy="$(make_decoy)"
export STATE_DIR="$decoy"
make_env
assert_no "make_env: STATE_DIR no longer points at the live project" \
  bash -c "[[ '$STATE_DIR' == '$decoy' ]]"
assert_no "make_env: CONFIG no longer points at the live config" \
  bash -c "[[ '$CONFIG' == '$decoy/config' ]]"
assert_no "make_env: WORKTREES_DIR no longer points at the live worktrees" \
  bash -c "[[ '$WORKTREES_DIR' == '$decoy/worktrees' ]]"
assert_no "make_env: CHECKOUTS_DIR no longer points at the live checkouts" \
  bash -c "[[ '$CHECKOUTS_DIR' == '$decoy/checkouts' ]]"
# unit_checkout/bug_checkout return PROJECT_ROOT as THE checkout in single topology, so a stale one
# aims a test's git at the live repo. lib.sh:17 also defines it as the parent of STATE_DIR — hold that.
assert_no "make_env: PROJECT_ROOT no longer points at the live project" \
  bash -c "[[ '$PROJECT_ROOT' == "$(dirname "$decoy")" ]]"
assert_eq "$(cd "$PROJECT_ROOT" && pwd)" "$(cd "$STATE_DIR/.." && pwd)" \
  "make_env: PROJECT_ROOT stays the parent of STATE_DIR (lib.sh:17 invariant)"

finish
