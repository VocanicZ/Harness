#!/usr/bin/env bash
# test_poller_fd9.sh — ensure_poller must NOT leak start.sh's double-start lock (fd 9) into the
# nohup'd poller child. start.sh acquires the start-lock on fd 9 and, under HARNESS_USE_POLLER,
# calls ensure_poller WHILE fd 9 is still open (start.sh:101, before its own `exec 9>&-`). The
# poller is deliberately NEVER killed by `harness stop`, so if it inherits fd 9 it holds start.lock
# for its entire (fleet-outliving) life — a later `harness start --recover` then finds the lock
# held, prints "(another start in progress)", and launches ZERO workers. This is the exact wedge
# class already fixed for pool.sh/priority.sh (see test_start_lock.sh); the poller spawn was the
# remaining leak. The fix closes fd 9 on the poller spawn INSIDE ensure_poller (`9>&-`), so BOTH
# callers (start.sh and the worker snapshot_gate) are covered regardless of their own fd state.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
# host-root seams point at a temp dir (NOT real ~/.harness); set BEFORE sourcing lib.sh.
export HARNESS_HOME="$WORK/host"
export HARNESS_POLLER_DIR="$WORK/host/poller"
export STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"

LOCK="$WORK/start.lock"

# --- behavioural: mimic start.sh holding the start-lock on fd 9 while calling ensure_poller -------
# Hold fd 9 on the start-lock, fork the poller via ensure_poller (using the HARNESS_POLLER_CMD seam
# for a long-lived child), then drop fd 9 in THIS (parent) shell. If the poller child inherited fd
# 9, the lock stays held after the parent releases it.
( exec 9>"$LOCK"; flock -n 9 || exit 1
  HARNESS_POLLER_CMD='sleep 30' ensure_poller
  exec 9>&- )

assert_ok "ensure_poller does NOT leak the start-lock (fd 9) to the poller child" \
  flock -n 8 8>"$LOCK"

# cleanup the spawned poller child
pid="$(cat "$HARNESS_POLLER_DIR/poller.pid" 2>/dev/null || true)"; [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; sleep 0.2

# --- static guard: the production poller.sh spawn in lib.sh closes fd 9 (mirrors test_start_lock) -
assert_ok "ensure_poller spawns poller.sh with fd 9 closed for the child (9>&-)" \
  grep -Eq 'poller\.sh".*9>&-' "$HERE/../scripts/lib.sh"

finish
