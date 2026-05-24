#!/usr/bin/env bash
# priority-worker.sh — the priority bug lane (#26). A single resident worker (cap 1) that
# claims one bug-lane issue at a time, drives it, and releases it, polling at the fast
# HARNESS_PRIORITY_POLL cadence. Same pause/stop semantics as pool-worker.sh: pause drains
# (rc 3), stop kills the pid. Wiring only — drive_bug is a no-op stub here; the real
# triage/fix session lands in the next issue.
set -uo pipefail
_PW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_HARNESS_LIB_SOURCED:-}" ]]   && { source "$_PW_HERE/lib.sh";   _HARNESS_LIB_SOURCED=1; }
[[ -z "${_HARNESS_DRIVE_SOURCED:-}" ]] && { source "$_PW_HERE/drive.sh"; _HARNESS_DRIVE_SOURCED=1; }

# drive_bug <n> — take one claimed bug to resolution. WIRING ONLY (#26): a no-op/echo that
# proves the claim→drive→release lifecycle. Real triage/fix sessions land in the next issue.
# Sourced (overridable) so tests assert the lifecycle without touching GitHub.
drive_bug(){ log "priority lane: drive bug #$1 (no-op stub — real triage/fix lands later)"; }

# One claim cycle. rc 3 paused (drained, no claim), rc 0 claimed+drove+released a bug,
# rc 1 idle (no claimable bug). The lane holds at most one bug at a time (cap 1): it
# releases before returning, so it is structurally serial — a second bug always waits.
bug_tick(){ local wid="$1" n
  if is_paused; then return 3; fi
  n="$(claim_next_bug "$wid")"
  if [[ -z "$n" ]]; then return 1; fi
  log "priority $wid claimed bug #$n"; drive_bug "$n"; release_bug_claim "$n"; log "priority $wid released bug #$n"; return 0; }

# One poll cycle. Resident: idle (rc 1) logs a banner ONCE per idle streak (deduped via
# _IDLE_LOGGED) and keeps polling; real work (rc 0) clears the dedup so a later idle streak
# re-announces. The lane only ever terminates on stop (kill); pause keeps it drained (rc 3).
bug_step(){ local wid="$1"; bug_tick "$wid"; local rc=$?
  case "$rc" in
    0) _IDLE_LOGGED=0 ;;
    1) [[ "${_IDLE_LOGGED:-0}" == 1 ]] || { log "no bugs — idle, watching"; _IDLE_LOGGED=1; }
       sleep "$PRIORITY_POLL" ;;
    *) sleep "$PRIORITY_POLL" ;;
  esac
  return "$rc"; }
main(){ local wid="${1:-P1}"; UNIT="priority-$wid"; _IDLE_LOGGED=0
  log "priority lane $wid up — cap 1 poll ${PRIORITY_POLL}s"
  while true; do bug_step "$wid"; done; }
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
