#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUN_DIR="$(mktemp -d)"
out="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out" | grep -qiE "worker" && echo "  ok: status mentions workers" || { echo "  FAIL"; exit 1; }
echo "── status smoke ok"

# paused state renders "PAUSED": create the flag in the SAME RUN_DIR the status run uses
mkdir -p "$RUN_DIR"; touch "$RUN_DIR/PAUSED"
out3="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget RUN_DIR="$RUN_DIR" bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out3" | grep -qi paused && echo "  ok: status shows PAUSED when flag set" || { echo "  FAIL: no PAUSED"; exit 1; }

# --- IDLE/WATCHING verdict (#24): resident workers + all units complete -----------
# fleet_verdict is a pure helper; sourcing status.sh defines it (entrypoint is guarded).
source "$HERE/../status.sh"
# fleet_verdict <up> <total> <sess_total> <done_n> <all_n> <paused:0|1>
v_idle="$(fleet_verdict 3 3 0 2 2 0)"
echo "$v_idle" | grep -qi 'IDLE'     && echo "  ok: workers up + all units complete -> IDLE/WATCHING" || { echo "  FAIL: expected IDLE, got [$v_idle]"; exit 1; }
echo "$v_idle" | grep -qi 'WATCHING' || { echo "  FAIL: IDLE verdict missing WATCHING — got [$v_idle]"; exit 1; }

v_run="$(fleet_verdict 3 3 1 1 2 0)"   # work still pending
echo "$v_run" | grep -qi 'RUNNING'   && echo "  ok: workers up + work pending -> RUNNING" || { echo "  FAIL: expected RUNNING, got [$v_run]"; exit 1; }

v_stop="$(fleet_verdict 0 3 0 2 2 0)"  # no live workers even if complete -> STOPPED, not IDLE
echo "$v_stop" | grep -qi 'STOPPED'  && echo "  ok: no live workers -> STOPPED (distinct from IDLE)" || { echo "  FAIL: expected STOPPED, got [$v_stop]"; exit 1; }
echo "$v_stop" | grep -qi 'IDLE'     && { echo "  FAIL: STOPPED must not read IDLE — got [$v_stop]"; exit 1; } || true

v_pause="$(fleet_verdict 3 3 0 2 2 1)" # paused overrides idle
echo "$v_pause" | grep -qi 'PAUSED'  && echo "  ok: paused overrides IDLE -> PAUSED" || { echo "  FAIL: expected PAUSED, got [$v_pause]"; exit 1; }
echo "── status IDLE/WATCHING ok"
