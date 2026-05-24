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

# ── #44 multi-topology: lane identity carries the repo end-to-end ────────────
# sess_bug emitted a BARE number, so every deriver that re-parsed the session/claim lost the repo
# in `multi`, where two repos can share issue #N. lane_bug must return a repo-qualified
# <owner>/<repo>#N ref so status renders the right bug (not the sanitised claim key like
# 'acme_a-6'), and lane_phase must match the repo-qualified session so the phase is not '?'.
MRUN="$(mktemp -d)"; MCLAIMS="$MRUN/claims"; mkdir -p "$MCLAIMS"
CLAIMS_DIR="$MCLAIMS"
sleep 30 & MLANE=$!
printf 'P1 %s acme/a#6\n' "$MLANE" > "$MCLAIMS/bug-acme_a-6.claim"
lb="$(lane_bug)"
[[ "$lb" == "acme/a#6" ]] && echo "  ok: multi lane_bug returns the repo-qualified token" || { echo "  FAIL: lane_bug — want [acme/a#6] got [$lb]"; kill "$MLANE" 2>/dev/null; exit 1; }
kill "$MLANE" 2>/dev/null

# Two repos each hold a bug #6 with a live session in DIFFERENT phases. lane_phase must match the
# repo-qualified session, so each repo's #6 reports its OWN phase — never a cross-repo mismatch or
# the bare-number '?' that the old un-repo-qualified grep produced.
tmux(){ printf 'hz-bug-acme_a-6-fix\nhz-bug-acme_b-6-triage\n'; }
pa="$(lane_phase acme/a#6)"; pb="$(lane_phase acme/b#6)"
[[ "$pa" == "fix" ]]    && echo "  ok: multi lane_phase(acme/a#6) -> fix"    || { echo "  FAIL: lane_phase acme/a#6 — want [fix] got [$pa]"; exit 1; }
[[ "$pb" == "triage" ]] && echo "  ok: multi lane_phase(acme/b#6) -> triage (no cross-repo mismatch)" || { echo "  FAIL: lane_phase acme/b#6 — want [triage] got [$pb]"; exit 1; }
unset -f tmux

# End-to-end render in `multi`: the lane row shows the repo-qualified bug WITH its phase, never the
# sanitised claim key (acme_a-6) or the perpetual '?' phase the old bare-number grep produced.
ERUN="$(mktemp -d)"; mkdir -p "$ERUN/claims"
sleep 30 & EP=$!
echo "$EP" > "$ERUN/priority.pid"
printf 'P1 %s acme/a#6\n' "$EP" > "$ERUN/claims/bug-acme_a-6.claim"
tmux(){ case "$1" in ls) printf 'hz-bug-acme_a-6-fix\n';; has-session) return 1;; *) return 0;; esac; }
export -f tmux
ETSV="$(mktemp)"   # empty targets.tsv -> no unit loops, hermetic
oute="$(HARNESS_TOPOLOGY=multi HARNESS_OWNER=acme TARGETS_TSV="$ETSV" RUN_DIR="$ERUN" bash "$HERE/../status.sh" 2>&1 || true)"
kill "$EP" 2>/dev/null; unset -f tmux
echo "$oute" | grep -qE 'bug acme/a#6 \(fix\)' && echo "  ok: multi lane row renders the repo-qualified bug + phase" || { echo "  FAIL: lane row not 'bug acme/a#6 (fix)' — got [$(echo "$oute" | grep -i 'bug ')]"; exit 1; }
echo "$oute" | grep -q 'acme_a-6'  && { echo "  FAIL: sanitised claim key leaked into the render"; exit 1; } || echo "  ok: sanitised key not shown"
echo "── status #44 multi lane-identity ok"
