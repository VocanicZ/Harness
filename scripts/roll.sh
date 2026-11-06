#!/usr/bin/env bash
# roll.sh — fleet_roll: the ONE rolling restart of a fleet's workers onto the current engine release
# (#477). `harness supervise` calls it after it installs a release (auto-update); `harness update` of
# PRD #464 / #467 calls the SAME function — there is no second kill-and-relaunch implementation. A
# worker runs from the release directory it started on for its whole life (ENGINE_DIR is the realpath
# of bin/harness), so flipping $HARNESS_HOME/engine reaches no running worker; only a relaunch does.
#
# Sourced, never run. Needs scripts/portable.sh (lock_acquire, proc_env). Never `harness stop`:
# stop.sh kills every lane session. Only a pool or priority WORKER process is killed, and only while
# it holds no bug claim; the lane sessions it drove keep running and the relaunched worker adopts them
# (count_team_sessions / watchdog_team).
#
#   fleet_roll <state dir> <engine dir> <harness bin> [dry] [stop-only]
#     engine dir   the release the workers must run from (its realpath is compared with each worker's
#                  ENGINE_DIR); harness bin: the stable $HARNESS_HOME/engine/bin/harness
#     dry (1)      log what would be killed and started, change nothing
#     stop-only (1) kill the old-engine workers but relaunch nothing: `harness start` (start.sh) is
#                  already launching the workers itself and must not recurse into another start (#566)
#   Kills each run/worker-*.pid and run/priority.pid process whose ENGINE_DIR is not <engine dir>:
#     - under the fleet's run/pool.lock (the lock claim_bug / claim_first_bug take), so the worker
#       cannot claim something between the check and the kill;
#     - never one holding a BUG claim (run/claims/bug-*.claim naming its pid): it is mid-session. It
#       is counted as deferred and rolled by a later call, once the claim is released. A worker
#       holding a UNIT claim is rolled at once: the next worker claims the unit and adopts its lanes.
#   then `harness --state-dir <fleet> start` (never --recover) relaunches the missing ones. A paused
#   fleet is rolled too and stays paused (start.sh keeps PAUSED under HARNESS_START_KEEP_PAUSE). A
#   fleet with no worker pid files was stopped on purpose and is skipped.
#   Reports through ROLL_RESULT (a file, when set): "<killed> <deferred> <dead>" — dead = pid files
#   whose process is gone after the start. Logs each line through ROLL_LOG (a function; default echo).
[[ -n "${_HARNESS_ROLL_SOURCED:-}" ]] && return 0
_HARNESS_ROLL_SOURCED=1
_ROLL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -F lock_acquire >/dev/null || source "$_ROLL_HERE/portable.sh"

_roll_log(){ "${ROLL_LOG:-echo}" "$@"; }
# _roll_proc_engine <pid> — the realpath of a process's ENGINE_DIR, empty when unreadable.
_roll_proc_engine(){ local e; e="$(proc_env "$1" ENGINE_DIR)"; [[ -n $e ]] && realpath -m "$e"; return 0; }
# _roll_bug_claimed <run dir> <pid> — the pid holds a bug-lane claim.
_roll_bug_claimed(){ local f; for f in "$1"/claims/bug-*.claim; do
    [[ -f $f && "$(awk '{print $2; exit}' "$f" 2>/dev/null)" == "$2" ]] && return 0; done; return 1; }

fleet_roll(){
  local sd="$1" want hb="$3" dry="${4:-0}" stop_only="${5:-0}" run pf pid ed lockfd killed=0 deferred=0 dead=0 victims=() keep=() line w
  want="$(realpath -m "$2")"; run="$sd/run"
  [[ -n ${ROLL_RESULT:-} ]] && echo "0 0 0" >"$ROLL_RESULT"
  shopt -s nullglob; local pids=("$run"/worker-*.pid); shopt -u nullglob
  (( ${#pids[@]} )) || return 0                                    # stopped on purpose
  [[ -f $run/priority.pid ]] && pids+=("$run/priority.pid")
  for pf in "${pids[@]}"; do
    pid="$(cat "$pf" 2>/dev/null)"
    [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || continue
    ed="$(_roll_proc_engine "$pid")"
    [[ -n $ed ]] || { _roll_log "WARN roll: ${pf##*/} pid $pid: ENGINE_DIR unreadable — left alone"; continue; }
    [[ $ed == "$want" ]] && continue
    if (( dry )); then
      if _roll_bug_claimed "$run" "$pid"; then deferred=$((deferred+1)); _roll_log "DRY auto-update: would defer $pf pid $pid (bug claim, $ed)"
      else killed=$((killed+1)); _roll_log "DRY auto-update: would kill $pf pid $pid ($ed)"; fi
      continue
    fi
    lock_acquire "$run/pool.lock" lockfd
    if _roll_bug_claimed "$run" "$pid"; then
      deferred=$((deferred+1)); _roll_log "roll: $pf pid $pid holds a bug claim — rolled on a later pass"
    elif kill "$pid" 2>/dev/null; then
      killed=$((killed+1)); victims+=("$pid"); _roll_log "ACT roll: killed ${pf##*/} pid $pid ($ed)"
    fi
    lock_release "$lockfd"
  done
  # a killed worker has to be gone before start.sh looks at its pid file ("already running"); KILL one
  # that ignores TERM — it holds no claim, so nothing is lost.
  for pid in "${victims[@]}"; do
    for w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && { kill -9 "$pid" 2>/dev/null; sleep 0.2; }
  done
  # stop-only: the caller (start.sh's own launch, #566) relaunches the dead pid files — never a nested start
  if (( stop_only )); then [[ -n ${ROLL_RESULT:-} ]] && echo "$killed $deferred 0" >"$ROLL_RESULT"; return 0; fi
  # a dead pid file (a worker that did not come back, or one the roll just killed) -> relaunch
  for pf in "${pids[@]}"; do
    pid="$(cat "$pf" 2>/dev/null)"; [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || dead=$((dead+1))
  done
  if (( ! dry && dead > 0 )); then
    [[ -f $run/PAUSED ]] && keep=(HARNESS_START_KEEP_PAUSE=1)
    while IFS= read -r line; do _roll_log "  start: $line"; done < <(
      env -C "$(dirname "$sd")" ${keep[@]+"${keep[@]}"} "$hb" --state-dir "$sd" start 2>&1 </dev/null)
    dead=0
    for pf in "${pids[@]}"; do
      pid="$(cat "$pf" 2>/dev/null)"; [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || dead=$((dead+1))
    done
  elif (( dry && dead > 0 )); then
    _roll_log "DRY auto-update: would run harness start --state-dir $sd"
  fi
  [[ -n ${ROLL_RESULT:-} ]] && echo "$killed $deferred $dead" >"$ROLL_RESULT"
  return 0
}
