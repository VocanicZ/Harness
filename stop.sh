#!/usr/bin/env bash
# stop.sh [--clean] — stop all pool workers and their claude sessions.
# --clean also removes per-issue git worktrees (uncommitted work in them is lost).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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
for s in $(tmux ls -F '#S' 2>/dev/null | grep -E "^${HARNESS_SESS_PREFIX}-" || true); do
  tmux kill-session -t "$s" 2>/dev/null && echo "  killed tmux $s"
done

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
