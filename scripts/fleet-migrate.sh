#!/usr/bin/env bash
# fleet-migrate.sh [--all] [--state-dir <dir>] [--no-start] — move fleets to the one-repo config and
# roll their workers onto the engine this runs from (#467, PRD #464 §4). `scripts/migrate.sh` is the
# vendored→state converter; this is a different job.
#
#   --all          every fleet registered in $HARNESS_FLEETS_DIR (default $HARNESS_HOME/fleets/*.json),
#                  not only the current folder's; `harness update` runs this. The current folder's
#                  fleet is migrated too when it is not registered — and rolled only if it has live
#                  workers (a stopped fleet is not started by an update).
#   --state-dir D  one fleet (default: $STATE_DIR). `harness start` runs this for its own fleet with
#                  --no-start: start.sh launches the workers itself, right after.
#   --no-start     migrate and kill the old workers, but leave the launch to the caller.
#   --quiet        print nothing for a fleet that needs nothing.
#
# Per fleet, in order — and only when its config still needs it (a config already on HARNESS_UNIT
# with no HARNESS_TOPOLOGY is left alone, so running this twice changes nothing):
#   1. back up the config as config.bak-<date>;      2. migrate the config (scripts/fleet_migrate.py);
#   3. kill ONLY this fleet's run/worker-*.pid and run/priority.pid processes — never `harness stop`,
#      which kills every fleet's sessions: lane sessions keep running;
#   4. `harness start --state-dir <fleet>` (no --recover) relaunches the workers on this engine.
# A migrated config under old, un-rolled workers would leave them reading a missing targets.tsv and
# idling as "all complete", so the config and the roll always go together. A PAUSED fleet is
# migrated and its workers stopped, but not started: `harness start` would lift the pause —
# `harness resume` starts it on the new engine.
set -uo pipefail
ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
FLEETS_DIR="${HARNESS_FLEETS_DIR:-$HARNESS_HOME/fleets}"
source "$ENGINE_DIR/scripts/portable.sh"

ALL=0; START=1; QUIET=0; TARGET=""
while (($#)); do
  case "$1" in
    --all) ALL=1;;
    --no-start) START=0;;
    --quiet) QUIET=1;;     # say nothing for a fleet that needs nothing (harness start, every time)
    --state-dir) shift; TARGET="${1:-}";;
    --state-dir=*) TARGET="${1#--state-dir=}";;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "fleet-migrate: unknown argument: $1" >&2; exit 2;;
  esac
  shift
done
[[ -n "$TARGET" ]] || TARGET="${STATE_DIR:-}"

# a fleet's identity must come from ITS config: a worker's exported environment (this may run from
# inside another fleet's session) would beat every `: "${KEY:=val}"` line of the fleet being started.
FLEET_ENV=(STATE_DIR RUN_DIR TARGETS_TSV CLAIMS_DIR POOL_LOCK PAUSE_FLAG HARNESS_MODE HARNESS_TOPOLOGY
  HARNESS_OWNER HARNESS_REPO HARNESS_UNIT HARNESS_CHECKOUT HARNESS_SPEC HARNESS_AUTONOMOUS HARNESS_POOL
  HARNESS_CAP HARNESS_POLL HARNESS_PRIORITY_POLL HARNESS_SESS_PREFIX HARNESS_WORKTREE_HOOK HARNESS_MAIN_REPO)

# stop_pidfile <pidfile> — SIGTERM the process, SIGKILL it if it is still there after ~5s, drop the
# file. Sets HAD_WORKERS=1 when there was a live process to stop.
stop_pidfile(){ local pf="$1" pid i; pid="$(cat "$pf" 2>/dev/null)"
  if proc_alive "$pid"; then
    HAD_WORKERS=1
    kill "$pid" 2>/dev/null
    for ((i = 0; i < 50; i++)); do proc_alive "$pid" || break; sleep 0.1; done
    proc_alive "$pid" && kill -KILL "$pid" 2>/dev/null
    echo "    killed $(basename "$pf" .pid) (pid $pid)"
  fi
  rm -f "$pf"; }

# migrate_fleet <state-dir> <start 1|0|live> — start: always / never / only if it had live workers.
# rc 0 fine (migrated or nothing to do), 1 a step failed.
migrate_fleet(){ local state="$1" start="$2" out rc lockh="" pf; HAD_WORKERS=0
  [[ -f "$state/config" ]] || { echo "fleet $state: no config here — skipped"; return 0; }
  mkdir -p "$state/run" 2>/dev/null
  # one migrator per fleet: a second `harness start` / update landing meanwhile would back the config up twice.
  lock_acquire "$state/run/fleet-migrate.lock" lockh || { echo "  could not take $state/run/fleet-migrate.lock" >&2; return 1; }
  out="$(python3 "$ENGINE_DIR/scripts/fleet_migrate.py" config "$state")"; rc=$?
  if (( rc == 10 )); then lock_release "$lockh"; (( QUIET )) || echo "fleet $state: already one repo — nothing to do"; return 0; fi
  if (( rc != 0 )); then lock_release "$lockh"; echo "fleet $state: config migration FAILED (rc $rc) — workers left as they are" >&2; return 1; fi
  echo "fleet $state: migrated to one repo: $out"
  shopt -s nullglob
  for pf in "$state"/run/worker-*.pid "$state"/run/priority.pid; do stop_pidfile "$pf"; done
  shopt -u nullglob
  lock_release "$lockh"
  [[ "$start" == 0 || ( "$start" == live && $HAD_WORKERS == 0 ) ]] && return 0
  if [[ -e "$state/run/PAUSED" ]]; then
    echo "  paused — workers stopped, not started (harness start would lift the pause; 'harness resume' starts them on this engine)"
    return 0
  fi
  env "${FLEET_ENV[@]/#/-u}" bash "$ENGINE_DIR/bin/harness" start --state-dir "$state" \
    || { echo "  harness start FAILED for $state" >&2; return 1; }
  return 0; }

fail=0
if (( ALL )); then
  seen=" "
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    seen+="$(realpath -m "$p" 2>/dev/null || echo "$p") "
    migrate_fleet "$p" "$START" || fail=1
  done < <(python3 "$ENGINE_DIR/scripts/fleet_migrate.py" fleets "$FLEETS_DIR")
  # the folder `harness update` ran in, when it is not a registered (running) fleet: config only.
  if [[ -n "$TARGET" && -f "$TARGET/config" && "$seen" != *" $(realpath -m "$TARGET" 2>/dev/null || echo "$TARGET") "* ]]; then
    migrate_fleet "$TARGET" live || fail=1
  fi
elif [[ -n "$TARGET" ]]; then
  migrate_fleet "$TARGET" "$START" || fail=1
else
  echo "fleet-migrate: no fleet — pass --all or --state-dir <dir> (or run from a project)" >&2; exit 2
fi
exit "$fail"
