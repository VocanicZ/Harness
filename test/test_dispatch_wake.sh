#!/usr/bin/env bash
# test_dispatch_wake.sh — #1183 (PRD #1180 group B): event-driven dispatch. A lane end (session_end) or a PRD close
# (prd_closed) must start the next dispatch action within seconds, not after the next HARNESS_POLL (300s).
#   1. the wake stamp: harness_event writes it for session_end / prd_closed / child_filed / merged, nothing else
#   2. dispatch_nap: ends at once on a pending wake (also one written just before the nap), never lost, never spins,
#      and HARNESS_DISPATCH_WAKE=0 is the old single `sleep POLL`
#   3. snapshot_wake_refresh: one refresh per stamp however many workers ask, a follow-up only after 10s
#   4. a real worker_step loop on POLL=300 over a fake board whose snapshot is STALE until refreshed:
#      a. a fake lane end            -> the next dispatch action launches (latency asserted < 60s, in fact seconds)
#      b. a fake PRD close           -> the same
#      c. a SECOND worker napping on POLL (does not reap) wakes on the first one's lane end
# The loops run the real worker_step / worker_short_step / dispatch_nap / snapshot_wake_refresh / harness_event /
# close_prd on a real clock; only the GitHub side (gh, the snapshot writer, the claim read) is a file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"; source "$HERE/helpers.sh"

restore(){ source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/../scripts/pool-worker.sh"; unset -f sleep 2>/dev/null; }
setup(){  # [poll]
  restore; make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; HARNESS_UNIT=""
  POOL=2; POLL="${1:-300}"; HARNESS_TEND_TICK=1; HARNESS_TEND_IDLE_TICKS=3; HARNESS_USE_POLLER=1; HARNESS_DISPATCH_WAKE=1
  HARNESS_SNAPSHOTS_DIR="$RUN_DIR/snaps"; mkdir -p "$HARNESS_SNAPSHOTS_DIR"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_CLI=claude
  CALLS="$RUN_DIR/calls"; : > "$CALLS"
  BOARD="$RUN_DIR/board"; : > "$BOARD"           # what GitHub says now
  SNAP="$(poller_snapshot_path acme/widget)"; : > "$SNAP"   # what the host snapshot says: stale until refreshed
  log(){ :; }
  gh_budget_low(){ return 1; }
  poller_write_snapshot(){ echo "refresh $1" >> "$CALLS"; cp "$BOARD" "$(poller_snapshot_path "$1")"; }
  fleet_ctx; mkdir -p "$CLAIMS_DIR"
}
now(){ echo "${EPOCHREALTIME/,/.}"; }
# secs <from> <to> — the latency, to 0.1s
secs(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b - a}'; }
calls(){ grep -c "^$1" "$CALLS"; }

echo "=== 1. the wake stamp is written by the events that change the board, and only those ==="
setup
assert_eq "$(dispatch_wake_stamp)" "" "no stamp before any event"
for ev in session_end prd_closed child_filed merged; do
  before="$(dispatch_wake_stamp)"; harness_event "$ev" kind=impl issue=5; after="$(dispatch_wake_stamp)"
  assert_ok "harness_event $ev writes a new stamp" test -n "$after" -a "$after" != "$before"
done
before="$(dispatch_wake_stamp)"; harness_event nudge kind=impl issue=5; harness_event hold reason=other
assert_eq "$(dispatch_wake_stamp)" "$before" "nudge / hold events do not wake the pool"
before="$(dispatch_wake_stamp)"; dispatch_wake_request x; dispatch_wake_request x
assert_ok "two requests in one second still differ (a step between them must see both)" test "$(dispatch_wake_stamp)" != "$before"
HARNESS_DISPATCH_WAKE=0; before="$(dispatch_wake_stamp)"; harness_event session_end kind=impl issue=5
assert_eq "$(dispatch_wake_stamp)" "$before" "HARNESS_DISPATCH_WAKE=0: no stamp written"

echo "=== 2. dispatch_nap: interruptible, never lost, never spinning ==="
setup
sleep(){ echo "sleep $1" >> "$CALLS"; }
_WAKE_SEEN="$(dispatch_wake_stamp)"
dispatch_nap 6
assert_eq "$(tail -1 "$CALLS")" "sleep 2" "no wake: the nap sleeps in 2s slices"
assert_eq "$(calls sleep)" "3" "... 3 slices for 6s, and no more (no spin)"
: > "$CALLS"; dispatch_wake_request test   # written just BEFORE the nap begins: the race that would lose a wake
dispatch_nap 300
assert_eq "$(calls sleep)" "0" "a wake written before the nap starts ends it at once, without sleeping"
_WAKE_SEEN="$(dispatch_wake_stamp)"   # what the step that handled the wake does
: > "$CALLS"; dispatch_nap 4
assert_eq "$(calls sleep)" "2" "once the step has seen the stamp the next nap is full again (no busy loop)"
: > "$CALLS"; dispatch_nap 5
assert_eq "$(calls sleep)" "3" "an odd length ends on the remainder: 2 + 2 + 1"
assert_eq "$(tail -1 "$CALLS")" "sleep 1" "... the last slice is the 1s that is left, never over"
: > "$CALLS"; dispatch_nap 0; dispatch_nap abc
assert_eq "$(calls sleep)" "0" "nap 0 / junk: no sleep"
HARNESS_DISPATCH_WAKE=0; : > "$CALLS"; dispatch_wake_request x; dispatch_nap 300
assert_eq "$(cat "$CALLS")" "sleep 300" "HARNESS_DISPATCH_WAKE=0: the old single sleep POLL"
HARNESS_DISPATCH_WAKE=1; _WAKE_RETRY=2; : > "$CALLS"; worker_nap 300
assert_eq "$(calls sleep)" "$(( ${WAKE_RETRY_NAP:-20} / 2 ))" "after a wake that found nothing the nap is the short follow-up (${WAKE_RETRY_NAP:-20}s), not POLL"
_WAKE_RETRY=0; : > "$CALLS"; worker_nap 20
assert_eq "$(calls sleep)" "10" "no follow-up due: the full length"

echo "=== 3. snapshot_wake_refresh: one refresh per wake stamp, however many workers ask ==="
setup
snapshot_wake_refresh 0; snapshot_wake_refresh 0
assert_eq "$(calls refresh)" "0" "no wake yet: nothing to refresh for"
dispatch_wake_request a; snapshot_wake_refresh 0; snapshot_wake_refresh 0; snapshot_wake_refresh 0
assert_eq "$(calls refresh)" "1" "a wake: one refresh, however many workers ask"
snapshot_wake_refresh 1
assert_eq "$(calls refresh)" "1" "a follow-up inside 10s of the last refresh does not hit GitHub again"
echo "$(dispatch_wake_stamp)|1" > "$SNAP.wakeref"   # the last refresh was long ago
snapshot_wake_refresh 1
assert_eq "$(calls refresh)" "2" "a follow-up over 10s after the last refresh refreshes"
gh_budget_low(){ return 0; }; dispatch_wake_request b; snapshot_wake_refresh 0
assert_eq "$(calls refresh)" "2" "GitHub budget low: no refresh (ghrate)"
gh_budget_low(){ return 1; }; HARNESS_USE_POLLER=0; snapshot_wake_refresh 0
assert_eq "$(calls refresh)" "2" "poller off: no refresh (reads are direct and fresh)"

# --- the fake fleet for 4: real worker_step on a real clock, POLL=300 ----------------------------------------------
# GitHub is $BOARD (one action per line); the snapshot $SNAP only follows it when poller_write_snapshot runs (the
# host poller is not running here, so without a wake nothing refreshes it inside the test's minute). worker_tend
# reaps a lane when $RUN_DIR/lane.ended exists (session_end through the real harness_event, then the claim is
# released); worker_chores closes a PRD the snapshot lists as CLOSE_PRD (the real close_prd, a stub gh); worker_tick
# "launches" an IMPL line it reads from the SNAPSHOT, and records when.
fleet_stubs(){
  roots_check(){ :; }; gc_orphan_goals(){ :; }; gh_rate_wait(){ :; }; usage_watch(){ :; }; snapshot_gate(){ return 0; }
  sess_pane_pid(){ echo 4242; }; release_on_prd_close(){ :; }
  gh(){ echo "gh $*" >> "$CALLS"
    if [[ "$1 $2" == "issue close" ]]; then printf 'IMPL:9\n' > "$BOARD"; fi   # closing PRD #41 unblocks the next issue
    return 0; }
  worker_tend(){ local w="$1"
    [[ -f "$RUN_DIR/lane.ended" ]] || return 1
    mv "$RUN_DIR/lane.ended" "$RUN_DIR/lane.ended.done" 2>/dev/null || return 1   # one reaper wins
    harness_event session_end kind=impl issue=5; lane_release impl-5 "$w"; return 0; }
  worker_chores(){ local a
    while IFS=: read -r a n; do [[ "$a" == CLOSE_PRD ]] && close_prd "$n"; done < "$SNAP"; return 0; }
  worker_tick(){ local w="$1" a n
    worker_has_claim "$w" && return 1
    [[ -f "$RUN_DIR/launched.$w" ]] && return 1
    while IFS=: read -r a n; do
      if [[ "$a" == IMPL ]]; then now > "$RUN_DIR/launched.$w"; echo "launch $w $n" >> "$CALLS"; return 0; fi
    done < "$SNAP"; return 1; }
}
loop(){ local w="$1"   # a worker process: main()'s loop, with the stubs above
  ( fleet_stubs; _WAKE_SEEN="$(dispatch_wake_stamp)"; _WAKE_RETRY=0; _IDLE_LOGGED=0
    while true; do worker_step "$w" >/dev/null 2>&1; done ) &
  LOOP_PIDS+=($!); }
stop_loops(){ local p; for p in "${LOOP_PIDS[@]:-}"; do [[ -n "$p" ]] || continue; pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; LOOP_PIDS=(); }
# wait_launch <file> <max s> — the epoch the launch was recorded, empty if it never was within <max> seconds
wait_launch(){ local f="$1" max="$2" t0; t0="$(now)"
  while [[ ! -s "$f" ]] && awk -v a="$t0" -v b="$(now)" -v m="$max" 'BEGIN{exit !(b - a < m)}'; do command sleep 0.1; done
  cat "$f" 2>/dev/null; }
LOOP_PIDS=(); trap stop_loops EXIT

echo "=== 4a. a fake lane end on POLL=300: the next dispatch action launches within 60s ==="
setup 300
echo "IMPL:7" > "$BOARD"          # the lane's merge just unblocked #7 on GitHub ... but the snapshot predates it
lane_claim_write impl-5 W1 IMPL:5 hz-main-i5 4242
loop W1; command sleep 3          # first step is full; the worker then ticks every HARNESS_TEND_TICK (1s) as the owner of a live lane
assert_eq "$(calls launch)" "0" "nothing launches while the lane lives and the snapshot is stale"
T0="$(now)"; touch "$RUN_DIR/lane.ended"   # the lane's session ends
LAT="$(wait_launch "$RUN_DIR/launched.W1" 60)"
stop_loops
assert_ok "the next dispatch action launched after the lane end" test -n "$LAT"
echo "  measured: lane end -> next launch ${LAT:+$(secs "$T0" "$LAT")}s (POLL=300, limit 60)"
assert_ok "within 60s of the lane's session_end" awk -v a="$T0" -v b="${LAT:-9999}" 'BEGIN{exit !(b - a < 60)}'
assert_ok "... in fact within 30s" awk -v a="$T0" -v b="${LAT:-9999}" 'BEGIN{exit !(b - a < 30)}'
assert_ok "the launch came from a refresh the wake forced" grep -q '^refresh acme/widget' "$CALLS"

echo "=== 4b. a fake PRD close on POLL=300: the next dispatch action launches within 60s ==="
setup 300
echo "CLOSE_PRD:41" > "$BOARD"; cp "$BOARD" "$SNAP"   # the snapshot is current: PRD #41 is reviewed and due to close
T0="$(now)"; loop W1
LAT="$(wait_launch "$RUN_DIR/launched.W1" 60)"
stop_loops
assert_ok "the engine closed the PRD (gh issue close)" grep -q '^gh issue close 41' "$CALLS"
assert_eq "$(calls 'gh issue close')" "1" "... once (the refresh ran before the next chores, so the stale CLOSE_PRD was not re-fired)"
assert_ok "prd_closed was logged" grep -q '"prd_closed"' "${HARNESS_EVENTS_FILE:-$HARNESS_HOME/events.jsonl}"
assert_ok "the next dispatch action launched after the PRD close" test -n "$LAT"
echo "  measured: PRD close -> next launch ${LAT:+$(secs "$T0" "$LAT")}s (POLL=300, limit 60)"
assert_ok "within 60s of the prd_closed" awk -v a="$T0" -v b="${LAT:-9999}" 'BEGIN{exit !(b - a < 60)}'

echo "=== 4c. a second worker napping on POLL wakes on the first one's lane end ==="
setup 300
echo "IMPL:7" > "$BOARD"
lane_claim_write impl-5 W1 IMPL:5 hz-main-i5 4242
loop W1; loop W2; command sleep 4   # W2 owns no lane and has nothing to claim: it is in its 300s nap
T0="$(now)"; touch "$RUN_DIR/lane.ended"
for _ in $(seq 1 300); do [[ -s "$RUN_DIR/launched.W1" || -s "$RUN_DIR/launched.W2" ]] && break; command sleep 0.1; done
stop_loops
LAT="$(cat "$RUN_DIR"/launched.W? 2>/dev/null | head -1)"
assert_ok "an issue launched after the lane end" test -n "$LAT"
echo "  measured: lane end -> next launch ${LAT:+$(secs "$T0" "$LAT")}s with two workers (POLL=300, limit 60)"
assert_ok "... within 60s" awk -v a="$T0" -v b="${LAT:-9999}" 'BEGIN{exit !(b - a < 60)}'
assert_eq "$(calls launch)" "1" "... by one worker only"

echo "=== 4d. HARNESS_DISPATCH_WAKE=0 keeps the old behaviour: the worker sits out POLL ==="
setup 300; HARNESS_DISPATCH_WAKE=0
echo "IMPL:7" > "$BOARD"
lane_claim_write impl-5 W1 IMPL:5 hz-main-i5 4242
loop W1; command sleep 3; touch "$RUN_DIR/lane.ended"; command sleep 8
stop_loops
assert_eq "$(calls launch)" "0" "wake off: still waiting 8s after the lane end (it would wake at the next POLL)"

finish
