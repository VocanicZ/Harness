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

# Claude Code's config is host state too. ensure_trusted seeds every config the launched pane could
# read — ~/.claude.json, $CLAUDE_CONFIG_DIR/.claude.json, and each ~/.claude-switch/accounts/*/ —
# so a suite run inside a live agent session (whose .bashrc exports CLAUDE_CONFIG_DIR) wrote fixture
# /tmp paths into the developer's real per-account config. make_env pins the seam and drops the
# inherited config dir.
export CLAUDE_CONFIG_DIR="$(mktemp -d)"
CCD_DECOY="$CLAUDE_CONFIG_DIR"
make_env
assert_eq "${CLAUDE_CONFIG_DIR-<unset>}" "<unset>" \
  "make_env: inherited CLAUDE_CONFIG_DIR is dropped"
assert_ok "make_env: HARNESS_CLAUDE_CONFIG pinned inside the throwaway RUN_DIR" \
  bash -c "[[ '$HARNESS_CLAUDE_CONFIG' == '$RUN_DIR'/* ]]"
( source "$HERE/../scripts/lib.sh"; HARNESS_AUTONOMOUS=true ensure_trusted "$(mktemp -d)" )
assert_no "make_env: ensure_trusted writes no config into the live config dir" \
  test -e "$CCD_DECOY/.claude.json"

# The live fleet's CONFIG, not just its paths. Config lines are `: "${VAR:=…}"`, so an inherited
# value BEATS the file by design — a suite running inside a live agent session (which exports the
# whole set) read that fleet's HARNESS_REPO / HARNESS_AUTONOMOUS in place of its own fixture's, and
# test_init.sh's round-trip assertion failed on a real machine while passing on a bare one. Pinning
# STATE_DIR could not help: nothing about this leak goes through a path.
#
# Asserted in a SUBSHELL, and against unset_inherited_config directly rather than via make_env: the
# drop has to happen before lib.sh is sourced (see helpers.sh), and this file has already sourced it.
( export HARNESS_REPO=live/production HARNESS_AUTONOMOUS=false HARNESS_MODE=planned \
         HARNESS_LABEL_READY=live-ready HARNESS_CI_GATE=0
  unset_inherited_config
  for v in HARNESS_REPO HARNESS_AUTONOMOUS HARNESS_MODE HARNESS_LABEL_READY HARNESS_CI_GATE; do
    [[ "${!v-<unset>}" == "<unset>" ]] || exit 1
  done
  # ...and the fixture's own value now wins where the live one used to.
  cfg="$(mktemp)"; printf ': "${HARNESS_REPO:=fixture/widget}"\n' > "$cfg"; source "$cfg"
  [[ "$HARNESS_REPO" == fixture/widget ]] ) \
  && { echo "  ok: inherited config is dropped and a fixture config round-trips"; TESTS_RUN=$((TESTS_RUN+1)); } \
  || { echo "  FAIL: fixture config still loses to the live env"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); }
# The host PATH pins must SURVIVE the drop — run.sh and make_env set them deliberately.
( unset_inherited_config
  [[ -n "${HARNESS_HOME:-}" && -n "${HARNESS_POLLER_DIR:-}" && -n "${HARNESS_SNAPSHOTS_DIR:-}" ]] ) \
  && { echo "  ok: the host path pins survive the drop"; TESTS_RUN=$((TESTS_RUN+1)); } \
  || { echo "  FAIL: the host path pins were dropped too"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); }
# run.sh must actually DO the drop — a helper nobody calls guards nothing.
assert_ok "run.sh drops inherited config before the suite loop" \
  grep -q 'unset_inherited_config' "$HERE/run.sh"
assert_ok "test_init.sh re-drops for a direct invocation" \
  grep -q 'unset_inherited_config' "$HERE/test_init.sh"

finish
