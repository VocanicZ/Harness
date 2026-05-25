#!/usr/bin/env bash
set -uo pipefail
_PW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_HARNESS_LIB_SOURCED:-}" ]]   && { source "$_PW_HERE/lib.sh";   _HARNESS_LIB_SOURCED=1; }
[[ -z "${_HARNESS_DRIVE_SOURCED:-}" ]] && { source "$_PW_HERE/drive.sh"; _HARNESS_DRIVE_SOURCED=1; }
worker_tick(){ local wid="$1" u
  if is_paused; then return 3; fi
  u="$(claim_next "$wid")"
  if [[ -z "$u" ]]; then all_complete && return 2; return 1; fi
  log "worker $wid claimed $u"; seed_if_needed "$u"; drive_unit "$u"; release_claim "$u"; log "worker $wid released $u"; return 0; }
# One poll cycle. Resident (#24): all_complete (rc 2) no longer retires the worker — it
# logs an idle banner ONCE per idle streak (deduped via _IDLE_LOGGED) and keeps polling.
# Real work (rc 0) clears the dedup so a later idle streak re-announces. Workers only ever
# terminate on stop (kill); pause keeps them drained (rc 3). Returns worker_tick's rc.
worker_step(){ local wid="$1"
  # PRD-B slice 3 (#72): with HARNESS_USE_POLLER set, gate dispatch on a fresh host snapshot. A
  # stale/missing/unknown-schema snapshot HOLDS new dispatch (claim nothing, no gh fallback) — the
  # gate relaunches the poller; we log a deduped banner and leave in-flight sessions running. Flag
  # OFF: snapshot_gate returns 0 and this loop is byte-for-byte today's.
  if ! snapshot_gate; then
    [[ "${_IDLE_LOGGED:-0}" == 1 ]] || { log "snapshot stale — holding, restarting poller"; _IDLE_LOGGED=1; }
    sleep "$POLL"; return 4
  fi
  worker_tick "$wid"; local rc=$?
  case "$rc" in
    0) _IDLE_LOGGED=0 ;;
    2) [[ "${_IDLE_LOGGED:-0}" == 1 ]] || { log "all COMPLETE — idle, watching"; _IDLE_LOGGED=1; }
       sleep "$POLL" ;;
    *) sleep "$POLL" ;;
  esac
  return "$rc"; }
main(){ local wid="${1:?usage: pool-worker.sh <worker-id>}"; UNIT="worker-$wid"; _IDLE_LOGGED=0
  log "pool worker $wid up — cap $CAP poll ${POLL}s"
  while true; do worker_step "$wid"; done; }
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
