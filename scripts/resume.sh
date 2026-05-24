#!/usr/bin/env bash
# resume.sh — clear the pause and pick work back up.
#   - removes the local PAUSED idle-flag;
#   - if a worker pool is alive here, workers resume claiming on their next tick
#     (they re-dispatch open agent-paused issues through the normal loop → resume.md);
#   - if NO pool is alive (e.g. a different machine), runs `start --recover` to launch one.
# Cross-machine resume needs no local state: paused work is tracked in GitHub (agent-paused label).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

rm -f "$PAUSE_FLAG"

alive=0
shopt -s nullglob
for pf in "$RUN_DIR"/worker-*.pid; do
  kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && { alive=1; break; }
done
shopt -u nullglob

if (( alive )); then
  echo "RESUMED — workers will pick up claiming (incl. any agent-paused issues) on the next poll."
else
  echo "No live pool here — launching with recovery (continues any GitHub-checkpointed work):"
  exec bash "$ENGINE_DIR/scripts/start.sh" --recover
fi
