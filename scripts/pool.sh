#!/usr/bin/env bash
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
echo "Launching $POOL pool worker(s) (cap=$CAP sessions/worker, poll=${POLL}s):"
for ((i=1; i<=POOL; i++)); do
  pidf="$RUN_DIR/worker-$i.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then echo "  worker-$i: already running (pid $(cat "$pidf"))"; continue; fi
  nohup bash "$ENGINE_DIR/scripts/pool-worker.sh" "$i" >"$RUN_DIR/worker-$i.log" 2>&1 &
  echo "$!" > "$pidf"; echo "  worker-$i: started (pid $!) — log $RUN_DIR/worker-$i.log"
done
