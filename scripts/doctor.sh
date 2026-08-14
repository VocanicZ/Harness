#!/usr/bin/env bash
# doctor.sh [--fix] — fleet health check focused on the lock wedges + stale local state that strand a
# pool. Report-only by default: it prints findings and the exact remediation, and exits non-zero if
# anything is wrong (so it scripts cleanly). `--fix` then clears stale pidfiles and reaps ORPHANED
# lock-holders — strictly scoped to THIS project (a holder of this project's own lockfile, that is
# not a tracked live worker), so a co-resident sibling fleet is never touched.
#
# Why this exists: start.sh's double-start flock is fd-based. A worker killed mid-poll can orphan a
# `sleep` child that inherited the fd and keeps start.lock held — so `start --recover` skips with
# "(another start in progress)" and launches ZERO workers until the sleep elapses. fuser/lsof aren't
# guaranteed on the host (this box has neither), so the reliable answer comes from a /proc fd scan
# (lib: lock_holders). Sourced by test/test_doctor.sh; runs main only when executed directly.
set -uo pipefail
[[ -n "${_DOCTOR_SOURCED:-}" ]] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DOCTOR_FIX=0

# doctor_locks — for each fleet lock, list holders, classify each as a tracked live worker (normal,
# esp. pool.lock held transiently during a claim) or an ORPHAN (the wedge). Echoes findings; with
# --fix, kills orphan holders. Prints nothing reassuring is suppressed. Returns the problem count.
doctor_locks(){
  local problems=0 lf name pid rest sd kind
  for name in start.lock pool.lock; do
    lf="$RUN_DIR/$name"
    [[ -e "$lf" ]] || { echo "  $name: absent (never created — fine)"; continue; }
    if lock_free "$lf"; then echo "  $name: free ✓"; continue; fi
    echo "  $name: HELD"
    while IFS=$'\t' read -r pid rest; do
      [[ -n "$pid" ]] || continue
      sd="$(proc_state_dir "$pid")"
      if tracked_worker_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
        kind="tracked worker (normal — transient claim)"
      elif [[ "$name" == pool.lock ]]; then
        # pool.lock is held ONLY for the duration of a claim — by a tracked worker OR its short-lived
        # children (a forked pool-worker subprocess / an issuelib.py query). Those are NOT orphans;
        # flagging them is a false positive and (worse) --fix-killing one would corrupt a live claim.
        # So a pool.lock holder is never a problem and never a --fix target — report it informationally.
        kind="transient claim holder (normal)"
      else
        # Only a start.lock holder that is not a live tracked worker is a real wedge: the #88 fd-leak,
        # where a killed worker's orphaned poll-sleep keeps the inherited start.lock fd open and blocks
        # the next `start --recover` from launching any workers.
        kind="ORPHAN"; problems=$((problems+1))
      fi
      echo "      pid $pid [$kind]${sd:+  state_dir=$sd}  ${rest}"
      if (( DOCTOR_FIX )) && [[ "$kind" == ORPHAN ]]; then
        # Conservative: never kill a concurrent start.sh / harness process that legitimately holds
        # the lock for its run; the realistic culprit is an orphaned poll `sleep`.
        if [[ "$rest" == *start.sh* || "$rest" == *"harness "* ]]; then
          echo "        ↳ left running (looks like an in-flight start — refusing to kill)"
        else
          kill "$pid" 2>/dev/null && echo "        ↳ killed orphan $pid" || echo "        ↳ kill failed (already gone?)"
        fi
      fi
    done < <(lock_holders "$lf")
  done
  return "$problems"
}

# doctor_pidfiles — RUN_DIR/*.pid whose process is dead are stale (a clean stop removes them; a crash
# leaves them, and they make status/recover misreport). Report them; with --fix, remove them.
doctor_pidfiles(){
  local problems=0 p pid
  shopt -s nullglob
  for p in "$RUN_DIR"/*.pid; do
    pid="$(cat "$p" 2>/dev/null)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "  $(basename "$p"): live (pid $pid) ✓"
    else
      problems=$((problems+1))
      echo "  $(basename "$p"): STALE (pid ${pid:-?} dead)"
      (( DOCTOR_FIX )) && { rm -f "$p" && echo "        ↳ removed stale pidfile"; }
    fi
  done
  shopt -u nullglob
  return "$problems"
}

# doctor_fleets — stale entries in the host-wide fleet registry. A fleet killed with -9 or lost to a
# host crash never reaches stop.sh's fleet_deregister, so its prefix reservation lingers. The start
# guard prunes such entries on its own, but an operator who wants the host clean now needs a lever —
# this is it. Report-only by default; --fix prunes. A LIVE fleet is never touched. Returns the
# problem count, matching doctor_locks.
doctor_fleets(){
  local problems=0 pfx prj rd slugs
  [[ -d "$HARNESS_FLEETS_DIR" ]] || { echo "  fleet registry: absent (never created — fine)"; return 0; }
  while IFS=$'\t' read -r pfx prj rd slugs; do
    [[ -n "$pfx" ]] || continue
    if fleet_stale "$pfx" "$rd"; then
      problems=$((problems+1))
      echo "  fleet registry: STALE entry — prefix '$pfx' reserved by $prj (no live sessions, no live pids)"
      if (( DOCTOR_FIX )); then
        fleet_deregister "$prj"; echo "    → pruned"
      else
        echo "    → prune with: harness doctor --fix"
      fi
    fi
  done < <(fleet_registry_entries "")
  return $problems
}

doctor_main(){
  local a; for a in "$@"; do case "$a" in --fix) DOCTOR_FIX=1;; -h|--help) echo "usage: harness doctor [--fix]"; return 0;; esac; done
  local tag=""; (( DOCTOR_FIX )) && tag="(--fix) "
  echo "── harness doctor ${tag}── ${STATE_DIR:-?}"
  echo "RUN_DIR: $RUN_DIR"
  echo "locks:"
  local lp=0 pp=0 fp=0
  doctor_locks   || lp=$?
  echo "pidfiles:"
  doctor_pidfiles || pp=$?
  echo "fleet registry:"
  doctor_fleets   || fp=$?
  local total=$((lp+pp+fp))
  echo "────────────────────────────────────────────"
  if (( total == 0 )); then
    echo "healthy ✓ — no lock wedges or stale pidfiles."
    return 0
  fi
  if (( DOCTOR_FIX )); then
    # Re-check the locks after fixing so we report the resulting state honestly.
    echo "after --fix:"; doctor_locks >/dev/null; local now=0; lock_free "$RUN_DIR/start.lock" || now=1
    if (( now == 0 )); then echo "  start.lock now free ✓ — \`harness start --recover\` will launch workers."
    else echo "  start.lock still held — inspect above; a non-orphan (in-flight start) may hold it."; fi
    return 0
  fi
  echo "$total problem(s) found. To clear: harness doctor --fix   (kills only this project's orphans)"
  return 1
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && doctor_main "$@"
