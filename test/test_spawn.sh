#!/usr/bin/env bash
# test_spawn.sh — regression tests for spawn_orch / spawn_impl bugs:
#   C1: $SPEC unbound variable under set -u
#   I1: multi topology label leak when clone fails
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../drive.sh"
source "$HERE/helpers.sh"
make_env

# ── shared setup ─────────────────────────────────────────────────────────────
# A scratch dir that exists but is NOT a git repo (used for single-topology tests).
FAKE_CHECKOUT="$(mktemp -d)"
CALLS="$RUN_DIR/calls"

# drive_unit sets these as locals; for direct spawn_* calls we set them in scope.
UNIT=main
SLUG=acme/widget
PROJECT=main
DESC=widget

# Stub out everything that does real I/O so the test is hermetic.
# Each stub appends a record to $CALLS so we can inspect what was called.
stub_common(){
  : > "$CALLS"
  # tmux: always succeed, record the call
  tmux(){ echo "tmux $*" >> "$CALLS"; return 0; }
  # launch_claude: always succeed
  launch_claude(){ echo "launch_claude $*" >> "$CALLS"; return 0; }
  # render: always succeed (writes nothing to stdout — redirect in spawn_* goes to /dev/null via stub)
  render(){ echo "render $*" >> "$CALLS"; return 0; }
  # default_branch: return "main" without touching network
  default_branch(){ echo main; }
  # ensure_safe: no-op
  ensure_safe(){ :; }
}

# ── Test group 1: C1 — $SPEC must not be unbound ────────────────────────────
# We run spawn_impl and spawn_orch each in a subshell with set -uo pipefail
# so that any unbound-variable expansion causes an immediate nonzero exit.
# The tests assert the subshell exits 0 (no unbound-variable crash).

echo "=== C1: SPEC unbound variable ==="

# Single-topology spawn_impl
assert_ok "spawn_impl: no unbound-var crash (C1)" bash -c '
  set -uo pipefail
  HERE="'"$HERE"'"
  RUN_DIR="'"$RUN_DIR"'"
  WORKTREES_DIR="'"$WORKTREES_DIR"'"
  FAKE_CHECKOUT="'"$FAKE_CHECKOUT"'"
  source "'"$HERE"'/../lib.sh"
  source "'"$HERE"'/../drive.sh"
  # Stubs
  tmux(){ :; }; render(){ :; }; launch_claude(){ :; }
  default_branch(){ echo main; }; ensure_safe(){ :; }
  git(){ :; }; gh(){ :; }
  # HARNESS_SPEC intentionally empty (as in a fresh env); SPEC is never defined
  HARNESS_TOPOLOGY=single
  HARNESS_REPO=acme/widget
  HARNESS_SPEC=""
  # drive_unit locals — set here for direct spawn_impl call
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget
  CHECKOUT="$FAKE_CHECKOUT"
  PROMISE="ISSUE 5 DONE"; MAXITER=30; GOAL="ISSUE:5"
  spawn_impl 5 "ISSUE 5 DONE"
'

# Single-topology spawn_orch
assert_ok "spawn_orch: no unbound-var crash (C1)" bash -c '
  set -uo pipefail
  HERE="'"$HERE"'"
  RUN_DIR="'"$RUN_DIR"'"
  WORKTREES_DIR="'"$WORKTREES_DIR"'"
  FAKE_CHECKOUT="'"$FAKE_CHECKOUT"'"
  source "'"$HERE"'/../lib.sh"
  source "'"$HERE"'/../drive.sh"
  tmux(){ :; }; render(){ :; }; launch_claude(){ :; }
  default_branch(){ echo main; }; ensure_safe(){ :; }
  git(){ :; }; gh(){ :; }
  HARNESS_TOPOLOGY=single
  HARNESS_REPO=acme/widget
  HARNESS_SPEC=""
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget
  CHECKOUT="$FAKE_CHECKOUT"
  PROMISE="PLAN DONE"; MAXITER=8; GOAL="PLAN"
  spawn_orch PLAN "" "PLAN DONE"
'

# ── Test group 2: I1 — clone guard prevents label leak ───────────────────────
echo "=== I1: multi-topology clone guard ==="

# Sub-test A: when git clone FAILS, spawn_impl must return nonzero AND must NOT
# have called gh with --add-label (i.e. label is not applied before the guard).
CALLS_I1="$RUN_DIR/calls_i1"
assert_no "spawn_impl returns nonzero when clone fails (I1)" bash -c '
  set -uo pipefail
  HERE="'"$HERE"'"
  RUN_DIR="'"$RUN_DIR"'"
  WORKTREES_DIR="'"$WORKTREES_DIR"'"
  CALLS_I1="'"$CALLS_I1"'"
  : > "$CALLS_I1"
  source "'"$HERE"'/../lib.sh"
  source "'"$HERE"'/../drive.sh"
  # git: rev-parse fails (no repo) and clone fails; everything else succeeds and is recorded.
  # This precisely models a fresh $CHECKOUT dir that is not a git repo + a failing network clone.
  git(){
    echo "git $*" >> "$CALLS_I1"
    # "git -C <dir> rev-parse --git-dir" — signals "not a git repo" → trigger clone path
    [[ "$1" == -C && "$3" == rev-parse ]] && return 1
    # clone: fail to simulate network/permissions error
    [[ "$1" == clone ]] && return 1
    return 0
  }
  gh(){ echo "gh $*" >> "$CALLS_I1"; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS_I1"; return 0; }
  render(){ echo "render $*" >> "$CALLS_I1"; return 0; }
  launch_claude(){ echo "launch_claude $*" >> "$CALLS_I1"; return 0; }
  default_branch(){ echo main; }; ensure_safe(){ :; }
  HARNESS_TOPOLOGY=multi
  HARNESS_REPO=acme/widget
  HARNESS_SPEC=""
  FRESH_CHECKOUT="$(mktemp -d)"
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget
  CHECKOUT="$FRESH_CHECKOUT"
  PROMISE="ISSUE 5 DONE"
  spawn_impl 5 "ISSUE 5 DONE"
'

# Sub-test B: confirm no add-label call was recorded (label not leaked)
assert_eq "$(grep -c 'add-label' "$CALLS_I1" 2>/dev/null; true)" "0" \
  "gh --add-label NOT called when clone fails (I1 label leak)"

# Sub-test C: when clone succeeds, spawn_impl SHOULD apply the label
CALLS_I1_OK="$RUN_DIR/calls_i1_ok"
assert_ok "spawn_impl succeeds and labels when clone succeeds (I1)" bash -c '
  set -uo pipefail
  HERE="'"$HERE"'"
  RUN_DIR="'"$RUN_DIR"'"
  WORKTREES_DIR="$(mktemp -d)"
  CALLS_I1_OK="'"$CALLS_I1_OK"'"
  : > "$CALLS_I1_OK"
  source "'"$HERE"'/../lib.sh"
  source "'"$HERE"'/../drive.sh"
  git(){
    echo "git $*" >> "$CALLS_I1_OK"
    # rev-parse: always return 1 on first call (no repo yet), then 0 after clone
    if [[ "$1" == -C && "$3" == rev-parse ]]; then
      [[ -d "${2}/.git" ]] && return 0 || return 1
    fi
    # clone: succeed and create a minimal .git dir so rev-parse check passes afterwards
    if [[ "$1" == clone ]]; then
      tgt="${@: -1}"
      mkdir -p "$tgt/.git"
      return 0
    fi
    # worktree add: create the target dir so the render redirect succeeds
    if [[ "$1" == -C && "$3" == worktree ]]; then
      # find the target path argument (after "add -B <branch>")
      local i; for (( i=1; i<=$#; i++ )); do
        local a="${!i}"
        if [[ "$a" == "$WORKTREES_DIR"* ]]; then mkdir -p "$a"; break; fi
      done
    fi
    return 0
  }
  gh(){ echo "gh $*" >> "$CALLS_I1_OK"; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS_I1_OK"; return 0; }
  render(){ echo "render $*" >> "$CALLS_I1_OK"; return 0; }
  launch_claude(){ echo "launch_claude $*" >> "$CALLS_I1_OK"; return 0; }
  default_branch(){ echo main; }; ensure_safe(){ :; }
  HARNESS_TOPOLOGY=multi
  HARNESS_REPO=acme/widget
  HARNESS_SPEC=""
  FRESH_CHECKOUT="$(mktemp -d)"
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget
  CHECKOUT="$FRESH_CHECKOUT"
  PROMISE="ISSUE 5 DONE"
  spawn_impl 5 "ISSUE 5 DONE"
'

assert_eq "$(grep -c 'add-label' "$CALLS_I1_OK" 2>/dev/null || echo 0)" "1" \
  "gh --add-label called exactly once when clone succeeds (I1)"

finish
