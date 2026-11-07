#!/usr/bin/env bash
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/roll.sh"   # #647: fleet_slot_reconcile — a live worker no pid file names is adopted or stopped, never launched beside
# #602: the code this worker loads, so fleet_roll can tell it from a later fast-forward of the same engine dir
export HARNESS_ENGINE_STAMP="$(engine_stamp "$ENGINE_DIR")"
echo "Launching $POOL pool worker(s) (one lane each, poll=${POLL}s):"
for ((i=1; i<=POOL; i++)); do
  pidf="$RUN_DIR/worker-$i.pid"
  # #647: the pid file is not the only truth. A live worker of this fleet it does not name (overwritten, cleared as stale from
  # another pid namespace) is adopted into it, or stopped, before this slot launches — else it runs on beside the new one.
  fleet_slot_reconcile "$STATE_DIR" "worker-$i" "$ENGINE_DIR"; rc=$?
  (( rc == 2 )) && { echo "  worker-$i: NOT started — a live worker holding a bug claim is not in its pid file (see above)"; continue; }
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then echo "  worker-$i: already running (pid $(cat "$pidf"))"; continue; fi
  # detach_launch (portable.sh): nohup on POSIX; on Windows a launch that outlives the ssh session (#356).
  detach_launch "$pidf" "$RUN_DIR/worker-$i.log" bash "$ENGINE_DIR/scripts/pool-worker.sh" "$i" \
    || { echo "  worker-$i: FAILED to start — see above"; continue; }
  echo "  worker-$i: started (pid $(cat "$pidf")) — log $RUN_DIR/worker-$i.log"
done
# #647: a live worker of this fleet in no slot this pool launches (worker-7 of POOL=2) is stopped too, so the fleet never has more
# workers than POOL + the priority lane. One holding a bug claim is left for a later pass.
declare -A _strays=()
while read -r p s; do
  [[ $s == worker-* ]] || continue
  n="${s#worker-}"; [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= POOL )) && continue
  _strays[$s]=1
done < <(fleet_untracked_workers "$STATE_DIR")
if (( ${#_strays[@]} )); then for s in "${!_strays[@]}"; do fleet_slot_reconcile "$STATE_DIR" "$s" "$ENGINE_DIR" noadopt; done; fi
