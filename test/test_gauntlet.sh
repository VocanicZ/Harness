#!/usr/bin/env bash
# test_gauntlet.sh — gauntlet review: round counting (lib.sh) + spawn_orch render vars (drive.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/helpers.sh"
make_env

SLUG=acme/widget

echo "=== gauntlet_round ==="
# gauntlet_round reads a COUNT from `gh ... -q '... | length'`, so the stub returns the count.
gh(){ echo 0; }
assert_eq "$(gauntlet_round 7)" "1" "no markers -> round 1"

gh(){ echo 2; }
assert_eq "$(gauntlet_round 7)" "3" "two markers -> round 3"

gh(){ return 1; }
assert_eq "$(gauntlet_round 7)" "1" "gh failure -> round 1 (a transient error never fakes a concede)"

gh(){ echo "warning: template ignored"; }
assert_eq "$(gauntlet_round 7)" "1" "non-numeric gh output -> round 1"

echo "=== spawn_orch render vars ==="
UNIT=main; PROJECT=main; DESC=widget
STATE_DIR="$(mktemp -d)"
CHECKOUT="$(mktemp -d)"
CALLS="$RUN_DIR/calls"
HARNESS_TOPOLOGY=single
HARNESS_GAUNTLET_ROUNDS=3

# Stub every side effect; `render` records its argv so we can inspect the keys.
render(){ echo "render $*" >> "$CALLS"; return 0; }
launch_claude(){ :; }
default_branch(){ echo main; }
ensure_safe(){ :; }
run_worktree_hook(){ :; }
remove_worktree(){ :; }
# DECOMPOSE/REVIEW now render into their own per-PRD orch worktree, so the `worktree add` stub has
# to materialise the destination directory or the `> $wd/.harness-task.md` redirect never runs.
git(){ local a wt=""
  case "$*" in *"worktree add"*)
    for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && wt="$a"; done
    [[ -n "$wt" ]] && mkdir -p "$wt";; esac
  return 0; }
gh(){ echo 1; }        # one marker on the PRD -> this pass is round 2

: > "$CALLS"
spawn_orch REVIEW 7 "REVIEW DONE" >/dev/null 2>&1
# PRD-scoped: two concurrent REVIEWs must not share ref/, r<n>/A, r<n>/B or .mapping.
assert_ok "REVIEW: GAUNTLET_DIR lives under STATE_DIR, scoped to the PRD" \
  grep -q "GAUNTLET_DIR=$STATE_DIR/gauntlet/main/p7" "$CALLS"
assert_no "REVIEW: GAUNTLET_DIR never under CHECKOUT" \
  grep -q "GAUNTLET_DIR=$CHECKOUT" "$CALLS"
assert_ok "REVIEW: GAUNTLET_ROUND computed from markers (1 marker -> 2)" \
  grep -q "GAUNTLET_ROUND=2" "$CALLS"
assert_ok "REVIEW: GAUNTLET_ROUNDS passed through" \
  grep -q "GAUNTLET_ROUNDS=3" "$CALLS"

: > "$CALLS"
spawn_orch DECOMPOSE 7 "DECOMPOSE DONE" >/dev/null 2>&1
assert_ok "DECOMPOSE: GAUNTLET_ROUND rendered empty (no PRD payload to count)" \
  grep -qE "GAUNTLET_ROUND=( |\$)" "$CALLS"

finish
