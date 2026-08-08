#!/usr/bin/env bash
# helpers.sh — minimal bash test rig + temp-env setup for the harness pool logic.
# Sourced by test_*.sh AFTER sourcing ../scripts/lib.sh (and ../scripts/drive.sh where needed).
# Overrides unit_complete so tests control "which units are COMPLETE" without GitHub.
TESTS_RUN=0; TESTS_FAIL=0
assert_eq(){ TESTS_RUN=$((TESTS_RUN+1)); if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 — want [$2] got [$1]"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_ok(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  ok: $msg"; else echo "  FAIL: $msg — expected success from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_no(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  FAIL: $msg — expected failure from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); else echo "  ok: $msg"; fi; }
finish(){ echo "── $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"; [[ $TESTS_FAIL -eq 0 ]]; }
make_env(){
  RUN_DIR="$(mktemp -d)"; CLAIMS_DIR="$RUN_DIR/claims"; POOL_LOCK="$RUN_DIR/pool.lock"; PAUSE_FLAG="$RUN_DIR/PAUSED"; mkdir -p "$CLAIMS_DIR"
  # Hermetic state. lib.sh honours an inherited STATE_DIR (scripts/lib.sh:15) and every pool worker
  # exports its project's own to every child, so a test run inside a live agent session resolved
  # CONFIG / WORKTREES_DIR / CHECKOUTS_DIR at that fleet's REAL .harness/ and wrote to it. Re-pin
  # STATE_DIR and everything lib.sh derived from it; export it so child processes (init.sh, spawned
  # scripts) inherit the throwaway one too. Isolating WORKTREES_DIR per test was the old opt-in fix —
  # this makes it the default. See test_hermetic.sh.
  export STATE_DIR="$RUN_DIR/state"
  CONFIG="$STATE_DIR/config"; WORKTREES_DIR="$STATE_DIR/worktrees"; CHECKOUTS_DIR="$STATE_DIR/checkouts"
  mkdir -p "$WORKTREES_DIR" "$CHECKOUTS_DIR"
  TARGETS_TSV="$(mktemp)"; COMPLETE_SET="$(mktemp)"; POLL=0
  HARNESS_TOPOLOGY=multi   # tests that feed targets.tsv use multi; single-topology tests set it themselves
  unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
}
write_targets(){ cat > "$TARGETS_TSV"; }
set_complete(){ printf '%s\n' "$@" > "$COMPLETE_SET"; [[ $# -eq 0 ]] && : > "$COMPLETE_SET"; }
unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
