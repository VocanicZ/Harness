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
#   Kills each run/worker-*.pid and run/priority.pid process whose ENGINE_DIR is not <engine dir> — or whose code is
#   stale on a git-checkout engine updated in place (engine_stamp, #602):
#     - under the fleet's run/pool.lock (the lock claim_bug / claim_first_bug take), so the worker
#       cannot claim something between the check and the kill;
#     - never one holding a BUG claim (run/claims/bug-*.claim naming its pid): it is mid-session. It
#       is counted as deferred and rolled by a later call, once the claim is released. A worker
#       holding a UNIT claim is rolled at once: the next worker claims the unit and adopts its lanes.
#   Also kills (#643) a live worker of the retired unit-claim loop that no pid file names: the process of a 2-field
#   run/claims/<unit>.claim (a key that is no impl-/orch-/bug- lane), on another engine than <engine dir> or of an
#   unreadable one whose cmdline is a Harness worker; its claim file goes with it. One it cannot verify is a WARN, never a kill.
#   Also (#647) a live TOP-LEVEL worker of the fleet that NO pid file names — a pid file stops naming a live worker when it is
#   overwritten, cleared, or read from another pid namespace — is stopped (or, when it is the slot's only worker and already on this
#   engine, adopted into the slot's pid file) through fleet_slot_reconcile; one holding a bug claim is deferred. Each is logged
#   `ACT roll: stopped untracked …`, so a roll can no longer report success while an extra worker survives.
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

# _roll_stale_code <pid> <engine dir> — a worker already on this ENGINE_DIR still runs OLD code when `update` fast-forwarded a
# git-checkout engine in place (#602): the directory is the same, the scripts the worker loaded at start are not. True when the
# worker's HARNESS_ENGINE_STAMP differs from the engine's current one — or it has none (it predates the stamp: rolled once, the
# migration itself) and the engine is a git checkout. A release dir never changes under a worker, so there a missing stamp is fine.
_roll_stale_code(){ local ws cs; cs="$(engine_stamp "$2")"; [[ -n $cs ]] || return 1
  ws="$(proc_env "$1" HARNESS_ENGINE_STAMP)"
  if [[ -n $ws ]]; then [[ $ws != "$cs" ]]; else [[ -e $2/.git ]]; fi; }

# fleet_slot_reconcile <state dir> <slot> <engine dir> [noadopt] — #647: before anything launches <slot> (worker-N / priority) or a roll
# finishes, account for the live TOP-LEVEL workers of this fleet that no pid file names (fleet_untracked_workers) and belong to
# the slot. A pid file stops naming a live worker when it is overwritten, cleared as "stale" by a `start --recover` run from a
# pid namespace where every host pid looks dead, or leaked by a test; launching "into" it left the first worker running beside the
# new one, for good — the 24 orphan v0.5.0 workers of one fleet. Decides, per untracked worker, under run/pool.lock (so it cannot
# claim between the check and the kill) and never touching a lane session:
#   - slot already served by a live pid-file worker  -> TERM the extra, unless it holds a BUG claim (left, said so, stopped later)
#   - slot served by nobody                          -> ADOPT the first one on the current engine (its code not stale): the slot's
#                                                       pid file is rewritten to name it; the others are stopped as above
#   - none adoptable                                 -> TERM those holding no bug claim; a bug-claim holder is mid-session, so the
#                                                       slot is REFUSED (the caller launches nothing) and the pids are printed
# noadopt: never adopt (a slot nothing launches). Returns 0: the slot is free, launch it; 1: it is served (tracked or adopted), do not launch; 2: refused. Sets FSR_STOPPED (pids it
# signalled, already gone when it returns) and FSR_HELD (bug-claim holders it left running). Logs through _roll_log.
fleet_slot_reconcile(){
  local sd="$1" slot="$2" want run pf p s ed lockfd tracked="" adopt="" w line
  local cands=() held=() gone=()
  FSR_STOPPED=(); FSR_HELD=()
  want="$(realpath -m "$3")"; run="$sd/run"; pf="$run/$slot.pid"
  p="$(cat "$pf" 2>/dev/null)"; [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && tracked="$p"
  while read -r p s; do [[ -n $p && $s == "$slot" ]] && cands+=("$p"); done < <(fleet_untracked_workers "$sd")
  if (( ! ${#cands[@]} )); then [[ -n $tracked ]] && return 1; return 0; fi
  lock_acquire "$run/pool.lock" lockfd
  for p in "${cands[@]}"; do
    kill -0 "$p" 2>/dev/null || continue
    if _roll_bug_claimed "$run" "$p"; then held+=("$p"); continue; fi
    if [[ -z $tracked && -z $adopt && -z ${4:-} ]]; then
      ed="$(_roll_proc_engine "$p")"
      if [[ $ed == "$want" ]] && ! _roll_stale_code "$p" "$want"; then adopt="$p"; continue; fi
    fi
    if kill "$p" 2>/dev/null; then gone+=("$p"); _roll_log "ACT roll: stopped untracked $slot worker pid $p — no pid file names it${tracked:+, pid $tracked holds the slot}"; fi
  done
  [[ -n $adopt && -z $tracked ]] && { printf '%s\n' "$adopt" > "$pf"; _roll_log "ACT roll: adopted untracked $slot worker pid $adopt into ${pf##*/} (on the current engine)"; }
  lock_release "$lockfd"
  # a stopped worker has to be gone before its slot is launched; KILL one that ignores TERM — it holds no claim
  for p in ${gone[@]+"${gone[@]}"}; do
    for w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$p" 2>/dev/null && { kill -9 "$p" 2>/dev/null; sleep 0.2; }
  done
  FSR_STOPPED=(${gone[@]+"${gone[@]}"}); FSR_HELD=(${held[@]+"${held[@]}"})
  for p in ${held[@]+"${held[@]}"}; do
    if [[ -n $tracked || -n $adopt ]]; then _roll_log "WARN roll: untracked $slot worker pid $p holds a bug claim — left running, stopped on a later pass"
    else _roll_log "WARN roll: untracked $slot worker pid $p holds a bug claim — not stopped"; fi
  done
  [[ -n $tracked || -n $adopt ]] && return 1
  if (( ${#held[@]} )); then
    _roll_log "WARN roll: $slot NOT launched: live untracked worker pid ${held[*]} holds a bug claim (a second worker would race it); it is rolled once the claim is released"
    return 2
  fi
  return 0
}

# _roll_clean_env — the `-u VAR` words that drop this process's fleet config out of a child's environment (#649).
# lib.sh and every CLI adapter EXPORT the config they resolved (HARNESS_REPO, HARNESS_<CLI>_BIN/_FLAGS/_TIMEOUT, HARNESS_CLI,
# HARNESS_SESSION_BACKEND, …), and a fleet's config lines are `: "${VAR:=…}"`, so an inherited value beats the file. The process
# that rolls fleet B (`harness update` -> fleet-migrate --all, or supervise) has sourced lib.sh — for fleet A, or for none, which
# exports the engine DEFAULTS — so `harness start --state-dir B` handed B's workers `claude` instead of B's configured wrapper:
# every priority/bug lane on the host launched bare, outside the host's bwrap lane sandbox. B's start loads B's own config.
# Same rule as supervise's sup_clean_env: path seams (*_DIR/_DIRS/_HOME/_FILE/CONFIG*) and the supervisor's own knobs stay.
_roll_clean_env(){ local v
  for v in $(compgen -v HARNESS_); do
    case $v in *_DIR|*_DIRS|*_HOME|*_FILE|*CONFIG*|HARNESS_SUPERVISE_*|HARNESS_START_*|HARNESS_TEST_*|HARNESS_PLATFORM|HARNESS_GH_RATE_GUARD) ;; *) printf -- '-u\n%s\n' "$v";; esac
  done
  printf -- '-u\nRUN_DIR\n-u\nCLAIMS_DIR\n-u\nPOOL_LOCK\n-u\nPAUSE_FLAG\n'; }

fleet_roll(){
  local sd="$1" want hb="$3" dry="${4:-0}" stop_only="${5:-0}" run pf pid ed lockfd killed=0 deferred=0 dead=0 victims=() keep=() line w
  want="$(realpath -m "$2")"; run="$sd/run"
  [[ -n ${ROLL_RESULT:-} ]] && echo "0 0 0" >"$ROLL_RESULT"
  shopt -s nullglob; local pids=("$run"/worker-*.pid); shopt -u nullglob
  # stopped on purpose — unless a worker no pid file names is still running (#647): that fleet is not stopped
  if (( ! ${#pids[@]} )) && [[ -z "$(fleet_untracked_workers "$sd")" ]]; then return 0; fi
  [[ -f $run/priority.pid ]] && pids+=("$run/priority.pid")
  for pf in ${pids[@]+"${pids[@]}"}; do
    pid="$(cat "$pf" 2>/dev/null)"
    [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || continue
    ed="$(_roll_proc_engine "$pid")"
    [[ -n $ed ]] || { _roll_log "WARN roll: ${pf##*/} pid $pid: ENGINE_DIR unreadable — left alone"; continue; }
    if [[ $ed == "$want" ]]; then _roll_stale_code "$pid" "$want" || continue; fi
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
  # #643: a worker of the retired unit-claim loop is named by no pid file (a newer worker took worker-N.pid), only by its
  # 2-field `claims/<unit>.claim` — "<wid> <pid>", a key that is no impl-/orch-/bug- lane. It launches lanes the new
  # engine cannot see, so it is rolled like any old-engine worker.
  local cf ck cpid known lcmd
  shopt -s nullglob
  for cf in "$run"/claims/*.claim; do
    ck="$(basename "$cf" .claim)"; case "$ck" in impl-*|orch-*|bug-*) continue;; esac
    [[ "$(awk '{print NF; exit}' "$cf" 2>/dev/null)" == 2 ]] || continue
    cpid="$(awk '{print $2; exit}' "$cf" 2>/dev/null)"
    [[ $cpid =~ ^[0-9]+$ ]] && kill -0 "$cpid" 2>/dev/null || continue
    known=0; for pf in ${pids[@]+"${pids[@]}"}; do [[ "$(cat "$pf" 2>/dev/null)" == "$cpid" ]] && known=1; done
    (( known )) && continue                                          # a pid-file worker: handled above
    ed="$(_roll_proc_engine "$cpid")"
    if [[ -n $ed ]]; then
      if [[ $ed == "$want" ]]; then _roll_stale_code "$cpid" "$want" || continue; fi
    else
      lcmd="$(proc_cmdline "$cpid")"
      case "$lcmd" in *pool-worker.sh*|*scripts/drive.sh*|*scripts/pool.sh*) ed="unknown engine";;
        *) _roll_log "WARN roll: legacy claim ${cf##*/} pid $cpid: ENGINE_DIR unreadable and it is not a recognisable Harness worker — left alone"; continue;; esac
    fi
    if (( dry )); then
      killed=$((killed+1)); _roll_log "DRY auto-update: would kill legacy unit-claim worker pid $cpid (${cf##*/}, $ed)"; continue; fi
    lock_acquire "$run/pool.lock" lockfd
    if _roll_bug_claimed "$run" "$cpid"; then
      deferred=$((deferred+1)); _roll_log "roll: legacy worker pid $cpid holds a bug claim — rolled on a later pass"
    elif kill "$cpid" 2>/dev/null; then
      killed=$((killed+1)); victims+=("$cpid"); rm -f "$cf"
      _roll_log "ACT roll: killed legacy unit-claim worker pid $cpid (${cf##*/}, $ed) — no pid file named it"
    fi
    lock_release "$lockfd"
  done
  shopt -u nullglob
  # #647: a worker named by no pid file at all (the pid file was overwritten or cleared while it kept running). The pid-file loop
  # above never saw it, so a roll reported "all live workers current" while it kept claiming and reaping on old code. One of a
  # pid the legacy sweep above just stopped is already counted.
  local uw uslot uslots=() seen_slot=" "
  while read -r uw uslot; do
    [[ -n $uw ]] || continue
    for w in ${victims[@]+"${victims[@]}"}; do [[ $w == "$uw" ]] && continue 2; done
    kill -0 "$uw" 2>/dev/null || continue
    if (( dry )); then
      if _roll_bug_claimed "$run" "$uw"; then deferred=$((deferred+1)); _roll_log "DRY auto-update: would defer untracked $uslot worker pid $uw (bug claim)"
      else killed=$((killed+1)); _roll_log "DRY auto-update: would stop untracked $uslot worker pid $uw (no pid file names it)"; fi
      continue
    fi
    [[ $seen_slot == *" $uslot "* ]] || { seen_slot+="$uslot "; uslots+=("$uslot"); }
  done < <(fleet_untracked_workers "$sd")
  for uslot in ${uslots[@]+"${uslots[@]}"}; do
    fleet_slot_reconcile "$sd" "$uslot" "$want"
    killed=$((killed+${#FSR_STOPPED[@]})); deferred=$((deferred+${#FSR_HELD[@]}))
    # a slot that had no pid file at all but is now served (adopted) is a pid file the dead count below must see
    [[ -f $run/$uslot.pid ]] && { local known_pf=0; for pf in ${pids[@]+"${pids[@]}"}; do [[ $pf == "$run/$uslot.pid" ]] && known_pf=1; done; (( known_pf )) || pids+=("$run/$uslot.pid"); }
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
  for pf in ${pids[@]+"${pids[@]}"}; do
    pid="$(cat "$pf" 2>/dev/null)"; [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || dead=$((dead+1))
  done
  if (( ! dry && dead > 0 )); then
    [[ -f $run/PAUSED ]] && keep=(HARNESS_START_KEEP_PAUSE=1)
    local cleanenv=(); mapfile -t cleanenv < <(_roll_clean_env)
    while IFS= read -r line; do _roll_log "  start: $line"; done < <(
      env -C "$(dirname "$sd")" ${cleanenv[@]+"${cleanenv[@]}"} ${keep[@]+"${keep[@]}"} "$hb" --state-dir "$sd" start 2>&1 </dev/null)
    dead=0
    for pf in ${pids[@]+"${pids[@]}"}; do
      pid="$(cat "$pf" 2>/dev/null)"; [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || dead=$((dead+1))
    done
  elif (( dry && dead > 0 )); then
    _roll_log "DRY auto-update: would run harness start --state-dir $sd"
  fi
  [[ -n ${ROLL_RESULT:-} ]] && echo "$killed $deferred $dead" >"$ROLL_RESULT"
  return 0
}
