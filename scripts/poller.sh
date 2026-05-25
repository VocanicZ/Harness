#!/usr/bin/env bash
# poller.sh — the PRD-B host poller (#71). One host-level process refreshes a raw, versioned snapshot
# per REGISTERED repo into $HARNESS_SNAPSHOTS_DIR, so workers (slice 3) read snapshots instead of each
# polling GitHub. It is engine-level — it needs NO project STATE_DIR; its whole world is the host-root
# registry + snapshots dirs. The normal launch path is ensure_poller (lib.sh) via nohup; this script
# is also the documented debug/test entry behind `harness poll`.
#
#   (no args)   loop: refresh due slugs, sleep the fastest registered cadence, repeat. An EMPTY
#               registry makes it idle/exit (refcount 0 = nothing to poll); a worker tick relaunches
#               it via ensure_poller when work returns.
#   --once      one refresh pass over every registered slug, then exit (tests / manual refresh).
#   --status    report whether a poller is alive + the registered slugs and their cadences; exit 0.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
UNIT=poller

mode="${1:-loop}"

# refresh every registered slug once (deduped). Per-slug failures are logged, never fatal — one bad
# repo must not stop the others or kill the loop.
poll_once(){
  local slug
  while read -r slug; do
    [[ -n "$slug" ]] || continue
    if poller_write_snapshot "$slug"; then
      log "snapshot refreshed: $slug"
    else
      log "snapshot FAILED (left prior snapshot in place): $slug"
    fi
  done < <(poller_registry_slugs)
}

case "$mode" in
  --status)
    if poller_running; then echo "poller: RUNNING (pid $(cat "$POLLER_PID"))"; else echo "poller: not running"; fi
    echo "registry: $POLLER_REGISTRY_DIR"
    while read -r slug; do
      [[ -n "$slug" ]] || continue
      printf '  %s  cadence=%ss  snapshot=%s\n' "$slug" "$(poller_cadence_for "$slug")" "$(poller_snapshot_path "$slug")"
    done < <(poller_registry_slugs)
    exit 0
    ;;
  --once)
    poll_once
    exit 0
    ;;
  loop|"")
    # Single-instance + self-cleaning pidfile: record our pid; clear it on exit so ensure_poller
    # relaunches a crashed/finished poller on the next tick. (ensure_poller already wrote our pid
    # when it nohup'd us; we re-assert $$ — the same value — to also cover a direct `harness poll`.)
    mkdir -p "$HARNESS_POLLER_DIR"
    echo "$$" > "$POLLER_PID"
    trap 'rm -f "$POLLER_PID"' EXIT
    declare -A LAST=()
    while :; do
      mapfile -t slugs < <(poller_registry_slugs)
      # Empty registry → nothing references any repo (refcount 0): idle/exit. A returning fleet's
      # worker tick calls ensure_poller, which relaunches us.
      if [[ ${#slugs[@]} -eq 0 ]]; then
        log "registry empty — poller idle/exit"
        exit 0
      fi
      now="$(date +%s)"
      min_cad=""
      for slug in "${slugs[@]}"; do
        [[ -n "$slug" ]] || continue
        cad="$(poller_cadence_for "$slug")"
        [[ -z "$min_cad" || "$cad" -lt "$min_cad" ]] && min_cad="$cad"
        last="${LAST[$slug]:-0}"
        if (( now - last >= cad )); then
          poller_write_snapshot "$slug" && log "snapshot refreshed: $slug" || log "snapshot FAILED: $slug"
          LAST[$slug]="$now"
        fi
      done
      sleep "${min_cad:-$HARNESS_PRIORITY_POLL}"
    done
    ;;
  *)
    echo "usage: poller.sh [--once|--status]" >&2; exit 2
    ;;
esac
