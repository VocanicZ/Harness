#!/usr/bin/env bash
# pause.sh [--force] — pause the fleet.
#   (soft)   stop claiming/dispatching new work; workers idle; live sessions finish naturally.
#   --force  tell each live agent to checkpoint to GitHub (commit+push+/handoff comment+label),
#            then idle. Resumable from ANY machine. (implemented in a later step)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

force_pause(){ echo "force pause not yet implemented"; touch "$PAUSE_FLAG"; }

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1

if (( FORCE )); then
  force_pause   # defined below (Task 4)
else
  touch "$PAUSE_FLAG"
  echo "FLEET: PAUSED (draining) — workers stop claiming; live sessions finish. Resume: harness/resume.sh"
fi
