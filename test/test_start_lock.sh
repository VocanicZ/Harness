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

# One lock file PER pattern (#337): a buggy-pattern worker slow to die under load must not leave the
# lock held for the fixed-pattern check.
LOCK_BUG="$(mktemp -u)"; LOCK_FIX="$(mktemp -u)"; tmp_track "$LOCK_BUG" "$LOCK_FIX"

# helper: run start.sh's lock+spawn pattern with a given child-spawn redirection, leave a long-lived
# child alive, exit the "start.sh" parent, then report whether the lock is still held.
run_pattern(){ local redir="$1" pidf="$2" lock="$3"
  bash -c '
    redir="$1"; pidf="$2"; lock="$3"
    exec 9>"$lock"; flock -n 9 || exit 1
    if [[ "$redir" == close ]]; then nohup sleep 30 >/dev/null 2>&1 9>&- & else nohup sleep 30 >/dev/null 2>&1 & fi
    echo $! > "$pidf"
    exec 9>&-
  ' _ "$redir" "$pidf" "$lock"
}

# helper: is the lock free while the worker is still alive? `9>&-` is applied in the forked child
# AFTER fork(), so for a moment the async worker still holds the inherited fd 9 — and the flock with
# it — after the parent exits (#337). Poll up to a 5s wall-clock deadline rather than check once; the
# invariant is that the worker does not hold the lock for its LIFETIME. kill -0 at the moment the lock
# is found free stops a dead worker from passing.
lock_free_while_alive(){ local lock="$1" pid="$(cat "$2")" deadline=$(( ${EPOCHREALTIME//[!0-9]/} + 5000000 ))
  while (( ${EPOCHREALTIME//[!0-9]/} < deadline )); do
    if flock -n 8 8>"$lock"; then kill -0 "$pid" 2>/dev/null; return; fi
    sleep 0.1
  done
  return 1
}

# --- BUGGY pattern (child inherits fd 9): lock stays held after parent exits ---------------------
PIDF_BUG="$(mktemp)"; tmp_track "$PIDF_BUG"; run_pattern inherit "$PIDF_BUG" "$LOCK_BUG"
assert_no "leaked-fd pattern: lock is HELD by the live worker after start exits (documents the bug)" \
  flock -n 8 8>"$LOCK_BUG"
kill "$(cat "$PIDF_BUG")" 2>/dev/null

# --- FIXED pattern (child spawned with 9>&-): lock is free once parent exits ---------------------
PIDF_FIX="$(mktemp)"; tmp_track "$PIDF_FIX"; run_pattern close "$PIDF_FIX" "$LOCK_FIX"
assert_ok "fixed pattern (9>&-): lock is FREE after start exits even though the worker is still alive" \
  lock_free_while_alive "$LOCK_FIX" "$PIDF_FIX"
kill "$(cat "$PIDF_FIX")" 2>/dev/null

# --- static guard: start.sh must close fd 9 on the worker-script spawns --------------------------
assert_ok "start.sh spawns pool.sh with fd 9 closed for the child"     grep -Eq 'pool\.sh"?[[:space:]]+9>&-'     ../scripts/start.sh
assert_ok "start.sh spawns priority.sh with fd 9 closed for the child" grep -Eq 'priority\.sh"?[[:space:]]+9>&-' ../scripts/start.sh

# --- static guard: the start-lock must be acquired BEFORE the destructive recover() sweep --------
# #88: recover() runs recover_orphan_working (gh --remove-label writes) and sweep_orphan_bug_worktrees
# (`git worktree remove --force`/`rm -rf`); only clear_stale_claims inside it takes POOL_LOCK. If the
# `flock -n 9` start-lock is acquired AFTER `(( DO_RECOVER )) && recover`, two concurrent
# `start --recover` both enter recover() and race the worktree sweep + label writes. The whole
# invocation (recover + spawn) must be serialized under the start-lock, so the flock line must
# precede the recover call in source order. start.sh can't run end-to-end here (needs tmux/claude/gh),
# so this is a static line-order assertion (mirrors the seam-note rationale above).
flock_ln="$(grep -n 'flock -n 9'                 ../scripts/start.sh | head -1 | cut -d: -f1)"
recover_ln="$(grep -n 'DO_RECOVER )) && recover' ../scripts/start.sh | head -1 | cut -d: -f1)"
assert_ok "start.sh found a 'flock -n 9' line"                  test -n "$flock_ln"
assert_ok "start.sh found a '(( DO_RECOVER )) && recover' line" test -n "$recover_ln"
assert_ok "start.sh acquires the start-lock BEFORE running recover() (flock line $flock_ln < recover line $recover_ln)" \
  test "${flock_ln:-0}" -lt "${recover_ln:-0}"

finish
