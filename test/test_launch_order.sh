#!/usr/bin/env bash
# test_launch_order.sh — launch_claude must write the session's .goal file ONLY AFTER the tmux
# session exists, never before. Writing it first opens a cross-lane TOCTOU window: gc_orphan_goals
# (run by every OTHER lane's tick over the shared RUN_DIR) reaps any .goal whose session is not yet
# live, so a concurrent sweep in the goal-write→new-session gap deletes the goal of a session that
# is about to come up — losing it for reap_done_sessions (drive.sh) and inject's REVIEW check.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../scripts/lib.sh
source ./helpers.sh
make_env

SESS="hzli-unit-acme_widget-rev"
WD="$(mktemp -d)"; : > "$WD/.harness-task.md"
PROMISE="X DONE"; MAXITER=1; GOAL="REVIEW"
CLAUDE_BIN="true"; CLAUDE_FLAGS=""

# Stub the session-spawning side effects so launch_claude runs in the test harness.
sleep(){ :; }
log(){ :; }
ensure_trusted(){ :; }
ensure_bypass(){ :; }
# Intercept tmux: record whether the .goal file already exists at `new-session` time. With the bug
# (goal written first) it would exist; with the fix (goal written after) it must NOT exist yet.
GOAL_PRESENT_AT_NEWSESSION=unset
# has-session must report NOT live (return 1) so the #108 re-dispatch guard treats this as a fresh spawn.
tmux(){ if [[ "$1" == has-session ]]; then return 1; fi
        if [[ "$1" == new-session ]]; then
          [[ -f "$RUN_DIR/$SESS.goal" ]] && GOAL_PRESENT_AT_NEWSESSION=yes || GOAL_PRESENT_AT_NEWSESSION=no
        fi; return 0; }

launch_claude "$SESS" "$WD"

assert_eq "$GOAL_PRESENT_AT_NEWSESSION" "no" \
  "the .goal file does not exist yet when tmux new-session runs (written after the session is live)"
assert_ok "the .goal file exists once launch_claude returns" test -f "$RUN_DIR/$SESS.goal"

finish
