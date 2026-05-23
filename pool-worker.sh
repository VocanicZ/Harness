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
main(){ local wid="${1:?usage: pool-worker.sh <worker-id>}"; UNIT="worker-$wid"
  log "pool worker $wid up — cap $CAP poll ${POLL}s"
  while true; do worker_tick "$wid"; local rc=$?
    case "$rc" in 0) ;; 2) log "all COMPLETE — worker $wid retiring"; exit 0;; 3) sleep "$POLL";; *) sleep "$POLL";; esac
  done; }
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
