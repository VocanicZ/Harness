#!/usr/bin/env bash
# priority.sh — launch the single resident priority bug lane (#26). cap=1, so exactly one
# lane process; re-runnable (skips a lane already alive). Mirrors pool.sh for the pool.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
echo "Launching the priority bug lane (cap=1, poll=${PRIORITY_POLL}s):"
pidf="$RUN_DIR/priority.pid"
if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
  echo "  priority: already running (pid $(cat "$pidf"))"
else
  if detach_launch "$pidf" "$RUN_DIR/priority.log" bash "$ENGINE_DIR/scripts/priority-worker.sh" P1; then
    echo "  priority: started (pid $(cat "$pidf")) — log $RUN_DIR/priority.log"
  else echo "  priority: FAILED to start — see above"; fi
fi
