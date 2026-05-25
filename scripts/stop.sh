#!/usr/bin/env bash
# stop.sh [--clean] — stop all pool workers and their claude sessions.
# --clean also removes per-issue git worktrees (uncommitted work in them is lost).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
rm -f "$PAUSE_FLAG"   # a stopped fleet is not "paused"

CLEAN=0; [[ "${1:-}" == "--clean" ]] && CLEAN=1

echo "Stopping pool workers:"
shopt -s nullglob
for pidf in "$RUN_DIR"/*.pid; do
  [[ -e "$pidf" ]] || continue
  pid="$(cat "$pidf")"; name="$(basename "$pidf" .pid)"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null && echo "  killed $name (pid $pid)"
  fi
  rm -f "$pidf"
done
shopt -u nullglob

echo "Killing claude worker sessions:"
# PRD-B slice 4 (#73): match the FULL session grammar (fleet_session_re), not the bare `^<prefix>-`,
# so a sibling fleet's sessions (or a stray `<prefix>-…` tmux window) are never cross-killed.
for s in $(tmux ls -F '#S' 2>/dev/null | grep -E "$(fleet_session_re)" || true); do
  tmux kill-session -t "$s" 2>/dev/null && echo "  killed tmux $s"
done

# PRD-B slice 3 (#72): deregister this project's repos from the host poller, keyed on STATE_DIR. A
# slug another fleet still references stays polled (refcount); only when the last fleet deregisters
# does it fall out of the work list. We NEVER kill the poller here — it is a host-level background
# process (pid under HARNESS_POLLER_DIR, not RUN_DIR; not a tmux session), so the worker-session +
# pidfile sweeps above never touch it, and other fleets may still need it. Flag OFF: registry-blind
# (today's stop), so an un-flagged fleet sharing the host can't strip a flagged fleet's entries.
if [[ -n "${HARNESS_USE_POLLER:-}" ]]; then
  echo "Deregistering this project's repos from the host poller (refcount; poller left running):"
  poller_deregister "$STATE_DIR"
fi

if (( CLEAN )); then
  echo "Removing worktrees:"
  shopt -s nullglob
  for wd in "$WORKTREES_DIR"/*; do
    rm -rf "$wd" && echo "  removed $wd"
  done
  # Prune dangling worktree references in each checkout
  for repo in "$CHECKOUTS_DIR"/*; do
    [[ -d "$repo/.git" ]] && git -C "$repo" worktree prune 2>/dev/null || true
  done
  shopt -u nullglob
fi
echo "Stopped."
