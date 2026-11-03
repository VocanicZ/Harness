#!/usr/bin/env bash
# fleet-migrate.sh [--all] [--state-dir <dir>] [--no-start] — move fleets to the one-repo config and
# roll their workers onto the engine this runs from (#467, PRD #464 §4). `scripts/migrate.sh` is the
# vendored→state converter; this is a different job.
#
#   --all          every fleet registered in $HARNESS_FLEETS_DIR (default $HARNESS_HOME/fleets/*.json),
#                  not only the current folder's; `harness update` runs this. The current folder's
#                  fleet is migrated too when it is not registered.
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
#   4. fleet_roll (scripts/roll.sh, #477) runs `harness start --state-dir <fleet>` (no --recover) and
#      relaunches the workers on this engine.
# A migrated config under old, un-rolled workers would leave them reading a missing targets.tsv and
# idling as "all complete", so the config and the roll always go together. A PAUSED fleet comes back
# paused, and a fleet with no worker pid files (stopped on purpose) is migrated but not started.
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

# stop_pidfile <pidfile> — SIGTERM the process, SIGKILL it if it is still there after ~5s. The pid file
# stays: fleet_roll reads its dead pid as "relaunch this worker", and start.sh overwrites it.
stop_pidfile(){ local pf="$1" pid i; pid="$(cat "$pf" 2>/dev/null)"
  proc_alive "$pid" || return 0
  kill "$pid" 2>/dev/null
  for ((i = 0; i < 50; i++)); do proc_alive "$pid" || break; sleep 0.1; done
  proc_alive "$pid" && kill -KILL "$pid" 2>/dev/null
  echo "    killed $(basename "$pf" .pid) (pid $pid)"; }

# migrate_fleet <state-dir> <start 1|0> — rc 0 fine (migrated or nothing to do), 1 a step failed.
migrate_fleet(){ local state="$1" start="$2" out rc lockh="" pf
  [[ -f "$state/config" ]] || { echo "fleet $state: no config here — skipped"; return 0; }
  mkdir -p "$state/run" 2>/dev/null
  # one migrator per fleet: a second `harness start` / update landing meanwhile would back the config up twice.
  lock_acquire "$state/run/fleet-migrate.lock" lockh || { echo "  could not take $state/run/fleet-migrate.lock" >&2; return 1; }
  out="$(python3 "$ENGINE_DIR/scripts/fleet_migrate.py" config "$state")"; rc=$?
  if (( rc == 10 )); then lock_release "$lockh"; (( QUIET )) || echo "fleet $state: already one repo — nothing to do"; return 0; fi
  if (( rc != 0 )); then lock_release "$lockh"; echo "fleet $state: config migration FAILED (rc $rc) — workers left as they are" >&2; return 1; fi
  echo "fleet $state: migrated to one repo: $out"
  # every worker of this fleet is an old-loop worker whatever release it runs from, so unlike the
  # supervisor's auto-update roll (which skips workers already on the new release) all of them go.
  shopt -s nullglob
  for pf in "$state"/run/worker-*.pid "$state"/run/priority.pid; do stop_pidfile "$pf"; done
  shopt -u nullglob
  lock_release "$lockh"
  (( start )) || return 0
  # the relaunch is #477's fleet_roll (scripts/roll.sh): `harness start --state-dir` without --recover, a
  # paused fleet comes back paused, a fleet with no worker pid files (stopped on purpose) is skipped.
  # Run with no other fleet's keys in the environment: they would beat this fleet's config.
  ( unset "${FLEET_ENV[@]}"; source "$ENGINE_DIR/scripts/roll.sh"
    fleet_roll "$state" "$ENGINE_DIR" "$ENGINE_DIR/bin/harness" ) \
    || { echo "  relaunching the workers of $state FAILED" >&2; return 1; }
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
    migrate_fleet "$TARGET" 1 || fail=1
  fi
elif [[ -n "$TARGET" ]]; then
  migrate_fleet "$TARGET" "$START" || fail=1
else
  echo "fleet-migrate: no fleet — pass --all or --state-dir <dir> (or run from a project)" >&2; exit 2
fi
exit "$fail"
