#!/usr/bin/env bash
# test_lane_switch.sh — #618 (PRD #587): a lane switch (reap → spawn) stops paying serial `gh` round trips.
#   - default_branch asks GitHub once per fleet (cached in RUN_DIR for an hour), never caches a failure
#   - spawning an impl lane makes ONE `gh issue view` for its issue: labels, issue text and the parent PRD (stats
#     attribution) all come off that one answer (stubbed gh counts the calls)
#   - launch_agent no longer sleeps 1.5 s after starting the session
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENGINE_DIR="$(cd "$HERE/.." && pwd)"   # a lane exports ENGINE_DIR = the installed release; this tests THIS tree
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"

echo "-- default_branch: one gh repo view per fleet"
(
  make_env; SLUG=acme/widget; GHLOG="$RUN_DIR/gh.log"; : > "$GHLOG"; ANSWER=trunk
  gh(){ echo "gh $*" >> "$GHLOG"; [[ -n "$ANSWER" ]] && echo "$ANSWER"; [[ -n "$ANSWER" ]]; }
  assert_eq "$(default_branch)" trunk "first call: the repo's default branch"
  assert_eq "$(default_branch)" trunk "second call: same answer"
  assert_eq "$(default_branch)" trunk "third call: same answer"
  assert_eq "$(grep -c 'repo view' "$GHLOG")" 1 "three lane switches, ONE gh repo view"
  SLUG=acme/other; ANSWER=develop
  assert_eq "$(default_branch)" develop "another repo is cached on its own"
  # a stale cache (older than an hour) is asked again
  SLUG=acme/widget; ANSWER=main; touch -d '2 hours ago' "$RUN_DIR/default-branch.acme_widget"
  assert_eq "$(default_branch)" main "a cache older than an hour is refreshed"
  # a gh failure answers main and is NOT cached
  SLUG=acme/down; ANSWER=""
  assert_eq "$(default_branch)" main "gh down → main"
  assert_no "a failed answer is not cached" test -e "$RUN_DIR/default-branch.acme_down"
  ANSWER=trunk
  assert_eq "$(default_branch)" trunk "gh back → the real answer"
) || TESTS_FAIL=$((TESTS_FAIL+1))

echo "-- spawn_impl: ONE gh issue view for the lane's issue"
(
  make_env; unset -f git 2>/dev/null || true
  launch_claude(){ echo "launch $1" >> "$RUN_DIR/launch.log"; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }
  resume_handoff(){ :; }
  UNIT=main; SLUG=acme/widget; PROJECT=w; DESC=d; HARNESS_SPEC=""; IMPL_MAXITER=5
  CHECKOUT="$RUN_DIR/co"; git init -q "$CHECKOUT"
  git -C "$CHECKOUT" config user.email t@t; git -C "$CHECKOUT" config user.name t
  git -C "$CHECKOUT" commit -q --allow-empty -m init
  git -C "$CHECKOUT" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$WORKTREES_DIR"
  GHLOG="$RUN_DIR/gh.log"; : > "$GHLOG"
  CHILD='{"title":"[AFK] Build it","body":"## What to build\nx\n\n## Parent\n\n#5\n","labels":[{"name":"ready-for-agent"}],"comments":[]}'
  LONER='{"title":"[AFK] Alone","body":"## What to build\nx\n","labels":[{"name":"ready-for-agent"}],"comments":[]}'
  gh(){ echo "gh $*" >> "$GHLOG"
    case "$*" in
      "repo view "*) echo main;;
      "issue view 7 "*) echo "$CHILD";;
      "issue view 8 "*) echo "$LONER";;
      "issue view 5 "*) echo '{"number":5,"title":"PRD","body":"## Original request\n\nbuild it\n"}';;
      "issue list "*) echo '[]';;
      *) return 0;; esac; }
  spawn_impl 8 "ISSUE 8 DONE"
  assert_eq "$(grep -c '^gh issue view' "$GHLOG")" 1 "an unparented issue: ONE gh issue view in all"
  assert_eq "$(grep -c '^gh issue view 8 ' "$GHLOG")" 1 "…and it is the lane's own issue"
  assert_eq "$(grep -c '^gh repo view' "$GHLOG")" 1 "one gh repo view for the default branch"
  assert_eq "$STAT_PRD" "" "no parent → no PRD attribution"
  : > "$GHLOG"
  spawn_impl 7 "ISSUE 7 DONE"
  assert_eq "$(grep -c '^gh issue view 7 ' "$GHLOG")" 1 "a parented issue: ONE gh issue view of the lane's own issue (labels + text + parent)"
  assert_eq "$STAT_PRD" 5 "the parent PRD still attributes the session, read off that one answer"
  assert_eq "$(grep -c '^gh repo view' "$GHLOG")" 0 "the default branch came from the fleet's cache"
  assert_ok "the lane launched" grep -q 'launch ' "$RUN_DIR/launch.log"
  # gh down for the issue view: the old per-call fallback still runs (the parent is asked again), nothing breaks
  : > "$GHLOG"; git -C "$CHECKOUT" worktree remove --force "$WORKTREES_DIR/main-i7"
  gh(){ echo "gh $*" >> "$GHLOG"; case "$*" in "repo view "*) echo main;; *) return 1;; esac; }
  spawn_impl 7 "ISSUE 7 DONE"; assert_eq "$?" 0 "gh down: the lane still spawns"
  assert_eq "$STAT_PRD" "" "gh down: no attribution"
) || TESTS_FAIL=$((TESTS_FAIL+1))

echo "-- launch_agent: no fixed 1.5 s sleep after the session starts"
assert_no "scripts/lib.sh has no 'sleep 1.5'" grep -q 'sleep 1\.5' "$HERE/../scripts/lib.sh"
finish
