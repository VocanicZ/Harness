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

# --- priority lane factored into the verdict (#35) --------------------------
# fleet_verdict <up> <total> <sess> <done_n> <all_n> <paused> <lane_up>
# pool down (up=0) but the priority lane alive -> NOT STOPPED; the verdict reflects the lane.
v_lane="$(fleet_verdict 0 3 0 0 2 0 1)"
echo "$v_lane" | grep -qi 'STOPPED' && { echo "  FAIL: lane-only-alive must NOT be STOPPED — got [$v_lane]"; exit 1; } || true
echo "  ok: pool down + lane up -> NOT STOPPED"
echo "$v_lane" | grep -qiE 'lane|priority' && echo "  ok: lane-only verdict reflects the live lane" || { echo "  FAIL: verdict should mention the lane — got [$v_lane]"; exit 1; }
# pool down AND lane down -> STOPPED (unchanged precedence)
v_both_down="$(fleet_verdict 0 3 0 0 2 0 0)"
echo "$v_both_down" | grep -qi 'STOPPED' && echo "  ok: pool down + lane down -> STOPPED" || { echo "  FAIL: expected STOPPED, got [$v_both_down]"; exit 1; }
# paused still wins even with the lane up
v_lane_pause="$(fleet_verdict 0 3 0 0 2 1 1)"
echo "$v_lane_pause" | grep -qi 'PAUSED' && echo "  ok: paused wins over a live lane" || { echo "  FAIL: expected PAUSED, got [$v_lane_pause]"; exit 1; }
echo "── status lane-verdict ok"

# --- priority-lane row renders (#35) ----------------------------------------
# A lane DOWN (no priority.pid) still prints its row.
out_down="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget RUN_DIR="$(mktemp -d)" bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out_down" | grep -qiE 'priority lane' && echo "  ok: status renders a priority-lane row" || { echo "  FAIL: no priority-lane row"; exit 1; }

# Lane alive with no bug claimed -> row shows UP + "watching"; lane-only fleet NOT STOPPED end-to-end.
LRUN="$(mktemp -d)"; sleep 30 & LANE_PID=$!
echo "$LANE_PID" > "$LRUN/priority.pid"
out_watch="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget RUN_DIR="$LRUN" bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out_watch" | grep -qi 'watching' && echo "  ok: live lane with no bug shows 'watching'" || { echo "  FAIL: expected 'watching' in lane row"; kill "$LANE_PID" 2>/dev/null; exit 1; }
fleet_line="$(echo "$out_watch" | grep 'FLEET:')"
echo "$fleet_line" | grep -qi 'STOPPED' && { echo "  FAIL: lane-only-alive fleet reported STOPPED — got [$fleet_line]"; kill "$LANE_PID" 2>/dev/null; exit 1; } || true
echo "  ok: lane-only-alive fleet not reported STOPPED (end-to-end)"
kill "$LANE_PID" 2>/dev/null

# Lane holding a bug -> row shows the claimed bug number.
LRUN2="$(mktemp -d)"; sleep 30 & LANE2=$!
echo "$LANE2" > "$LRUN2/priority.pid"
mkdir -p "$LRUN2/claims"; printf 'P1 %s\n' "$LANE2" > "$LRUN2/claims/bug-42.claim"
out_bug="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget RUN_DIR="$LRUN2" bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out_bug" | grep -qi 'bug #42' && echo "  ok: lane row shows the claimed bug number" || { echo "  FAIL: lane row missing 'bug #42'"; kill "$LANE2" 2>/dev/null; exit 1; }
kill "$LANE2" 2>/dev/null
echo "── status priority-lane row ok"
