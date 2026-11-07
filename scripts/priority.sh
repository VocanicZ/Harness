#!/usr/bin/env bash
# priority.sh — launch the single resident priority bug lane (#26). one lane, so exactly one
# lane process; re-runnable (skips a lane already alive). Mirrors pool.sh for the pool.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# #602: the code this worker loads, so fleet_roll can tell it from a later fast-forward of the same engine dir
export HARNESS_ENGINE_STAMP="$(engine_stamp "$ENGINE_DIR")"
echo "Launching the priority bug lane (one lane, poll=${PRIORITY_POLL}s):"
pidf="$RUN_DIR/priority.pid"
if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
  echo "  priority: already running (pid $(cat "$pidf"))"
else
  if detach_launch "$pidf" "$RUN_DIR/priority.log" bash "$ENGINE_DIR/scripts/priority-worker.sh" P1; then
    echo "  priority: started (pid $(cat "$pidf")) — log $RUN_DIR/priority.log"
  else echo "  priority: FAILED to start — see above"; fi
fi
