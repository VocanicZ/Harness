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
  nohup bash "$ENGINE_DIR/scripts/priority-worker.sh" P1 >"$RUN_DIR/priority.log" 2>&1 &
  echo "$!" > "$pidf"; echo "  priority: started (pid $!) — log $RUN_DIR/priority.log"
fi
