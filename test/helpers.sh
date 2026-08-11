#!/usr/bin/env bash
# helpers.sh — minimal bash test rig + temp-env setup for the harness pool logic.
# Sourced by test_*.sh AFTER sourcing ../scripts/lib.sh (and ../scripts/drive.sh where needed).
# Overrides unit_complete so tests control "which units are COMPLETE" without GitHub.
TESTS_RUN=0; TESTS_FAIL=0
assert_eq(){ TESTS_RUN=$((TESTS_RUN+1)); if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 — want [$2] got [$1]"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_ok(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  ok: $msg"; else echo "  FAIL: $msg — expected success from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_no(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  FAIL: $msg — expected failure from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); else echo "  ok: $msg"; fi; }
finish(){ echo "── $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"; [[ $TESTS_FAIL -eq 0 ]]; }

# The per-project CONFIG vars lib.sh exports (scripts/lib.sh) — every one of which a pool worker
# hands down to the agent session that may be running this suite. Deliberately EXCLUDES the three
# host PATH pins (HARNESS_HOME / _POLLER_DIR / _SNAPSHOTS_DIR): run.sh and make_env set those to
# throwaways on purpose, so unsetting them here would undo the isolation.
HARNESS_CONFIG_VARS="HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC
  HARNESS_AUTONOMOUS HARNESS_POOL HARNESS_CAP HARNESS_POLL HARNESS_PRIORITY_POLL HARNESS_SESS_PREFIX
  HARNESS_LABEL_READY HARNESS_LABEL_PRD HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED
  HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD HARNESS_LABEL_PAUSED HARNESS_LABEL_BUG
  HARNESS_LABEL_BUG_TRIAGED HARNESS_MAIN_REPO HARNESS_AUTHOR_ALLOWLIST HARNESS_USE_POLLER
  HARNESS_PREFIX_COLLISION HARNESS_WORKTREE_HOOK HARNESS_GAUNTLET_ROUNDS HARNESS_CI_GATE"

# unset_inherited_config — drop a LIVE fleet's config out of the environment.
#
# The path pins alone were not enough. Config lines are written `: "${VAR:=value}"`, so a pre-set
# env var beats the file BY DESIGN — which means a suite running inside a live agent session read
# that fleet's HARNESS_REPO / HARNESS_AUTONOMOUS instead of the fixture's, and `harness init`'s
# round-trip assertion failed on a developer's machine while passing on a bare one. The product
# behaviour is correct; the test environment was the leak.
#
# CALL IT BEFORE lib.sh IS SOURCED, never after — which is why it is NOT part of make_env. lib.sh
# fills each var with its default at source time, but the runtime readers (sess_orch's
# $HARNESS_SESS_PREFIX, the label lookups) re-read the ENV on every call, so unsetting afterwards
# empties them mid-test rather than restoring defaults. run.sh drops them once before the loop, so
# every test gets a clean process; test_init.sh re-drops for a direct `bash test_init.sh`.
unset_inherited_config(){ unset $HARNESS_CONFIG_VARS; }
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
  # PROJECT_ROOT too: lib.sh:17 derives it from STATE_DIR at source time, and unit_checkout /
  # bug_checkout return it as THE checkout in single topology — leaving it behind would point a
  # test's git operations at the live repo, and would break lib.sh's own
  # "PROJECT_ROOT is the parent of STATE_DIR" invariant (test_path_split.sh).
  PROJECT_ROOT="$RUN_DIR"
  # Host-level state too (lib.sh:86-92). HARNESS_HOME defaults to ~/.harness and is NOT derived from
  # STATE_DIR, so pinning STATE_DIR alone still let tests write the real host poller registry — which
  # is shared by every co-resident fleet, so fixture entries there make `harness start` abort a real
  # fleet on a bogus prefix collision. Same seam, different root.
  export HARNESS_HOME="$RUN_DIR/host"
  # Claude Code's config too. ensure_trusted seeds EVERY config the launched pane could read —
  # ~/.claude.json, $CLAUDE_CONFIG_DIR/.claude.json, and each ~/.claude-switch/accounts/*/.claude.json
  # — so a test run inside a live agent session (which exports CLAUDE_CONFIG_DIR via .bashrc) wrote
  # fixture /tmp paths straight into the developer's real per-account config. Pin the seam to a
  # throwaway by default and drop the inherited config dir; tests that exercise the fan-out override
  # both explicitly (test_spawn.sh group 3b). Same seam, different root.
  export HARNESS_CLAUDE_CONFIG="$RUN_DIR/claude.json"
  unset CLAUDE_CONFIG_DIR
  export HARNESS_POLLER_DIR="$HARNESS_HOME/poller" HARNESS_SNAPSHOTS_DIR="$HARNESS_HOME/snapshots"
  POLLER_REGISTRY_DIR="$HARNESS_POLLER_DIR/registry"
  POLLER_PID="$HARNESS_POLLER_DIR/poller.pid"; POLLER_LOCK="$HARNESS_POLLER_DIR/poller.lock"
  mkdir -p "$WORKTREES_DIR" "$CHECKOUTS_DIR" "$POLLER_REGISTRY_DIR" "$HARNESS_SNAPSHOTS_DIR"
  TARGETS_TSV="$(mktemp)"; COMPLETE_SET="$(mktemp)"; POLL=0
  HARNESS_TOPOLOGY=multi   # tests that feed targets.tsv use multi; single-topology tests set it themselves
  unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
}
write_targets(){ cat > "$TARGETS_TSV"; }
set_complete(){ printf '%s\n' "$@" > "$COMPLETE_SET"; [[ $# -eq 0 ]] && : > "$COMPLETE_SET"; }
unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
