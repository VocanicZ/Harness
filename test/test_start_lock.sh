#!/usr/bin/env bash
# test_start_lock.sh — start.sh's double-start flock (fd 9 on start.lock) must NOT be inherited by
# the long-lived worker processes that pool.sh/priority.sh fork. If it is, a worker holds the lock
# for the whole life of the fleet, so a later `harness start --recover` (the documented re-runnable
# top-up path) finds the lock held, prints "(another start in progress)", and launches ZERO workers.
# The fix spawns the worker scripts with fd 9 closed (`9>&-`).
#
# Seam note: start.sh itself can't run in this harness (needs tmux/claude/gh), so this locks the
# invariant two ways — a behavioural test of the spawn idiom, and a static check that start.sh
# actually closes fd 9 on the worker spawns. Neither alone is a full end-to-end seam.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./helpers.sh

LOCK="$(mktemp -u)"

# helper: run start.sh's lock+spawn pattern with a given child-spawn redirection, leave a long-lived
# child alive, exit the "start.sh" parent, then report whether the lock is still held.
run_pattern(){ local redir="$1" pidf="$2"
  bash -c '
    redir="$1"; pidf="$2"; lock="$3"
    exec 9>"$lock"; flock -n 9 || exit 1
    if [[ "$redir" == close ]]; then nohup sleep 30 >/dev/null 2>&1 9>&- & else nohup sleep 30 >/dev/null 2>&1 & fi
    echo $! > "$pidf"
    exec 9>&-
  ' _ "$redir" "$pidf" "$LOCK"
}

# --- BUGGY pattern (child inherits fd 9): lock stays held after parent exits ---------------------
PIDF_BUG="$(mktemp)"; run_pattern inherit "$PIDF_BUG"
assert_no "leaked-fd pattern: lock is HELD by the live worker after start exits (documents the bug)" \
  flock -n 8 8>"$LOCK"
kill "$(cat "$PIDF_BUG")" 2>/dev/null; sleep 0.3

# --- FIXED pattern (child spawned with 9>&-): lock is free once parent exits ---------------------
PIDF_FIX="$(mktemp)"; run_pattern close "$PIDF_FIX"
assert_ok "fixed pattern (9>&-): lock is FREE after start exits even though the worker is still alive" \
  flock -n 8 8>"$LOCK"
kill "$(cat "$PIDF_FIX")" 2>/dev/null; sleep 0.3

# --- static guard: start.sh must close fd 9 on the worker-script spawns --------------------------
assert_ok "start.sh spawns pool.sh with fd 9 closed for the child"     grep -Eq 'pool\.sh"?[[:space:]]+9>&-'     ../scripts/start.sh
assert_ok "start.sh spawns priority.sh with fd 9 closed for the child" grep -Eq 'priority\.sh"?[[:space:]]+9>&-' ../scripts/start.sh

finish
