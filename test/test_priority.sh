#!/usr/bin/env bash
# test_priority.sh — the priority bug lane (#26): issue-level bug claims, single-agent
# serialization, stale-claim recovery, and resident pause/stop semantics.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env

# ── bug-claim lifecycle: claim records the worker id; is/release reflect it ────
# The GitHub-backed source of bug numbers is the overridable seam; everything else
# (claim files under CLAIMS_DIR, locking) is real.
_bug_numbers(){ printf '6\n7\n'; }
assert_eq "$(claimable_bugs | tr '\n' ' ')" "6 7 " "both bugs claimable when unclaimed"
got="$(claim_next_bug P1)"; assert_eq "$got" "6" "claim_next_bug returns first claimable bug"
assert_eq "$(awk '{print $1}' "$CLAIMS_DIR/bug-6.claim")" "P1" "claim records worker id"
assert_ok  "claimed bug is is_bug_claimed"          is_bug_claimed 6
assert_eq "$(claimable_bugs | tr '\n' ' ')" "7 " "claimed bug excluded -> only the other waits"
release_bug_claim 6
assert_ok "release removes the bug-claim file" bash -c "[[ ! -f '$CLAIMS_DIR/bug-6.claim' ]]"
assert_eq "$(claimable_bugs | tr '\n' ' ')" "6 7 " "released bug is claimable again"

# ── single-agent serialization: two simultaneous claimers get DIFFERENT bugs ──
( claim_next_bug A > "$RUN_DIR/ba.out" ) &
( claim_next_bug B > "$RUN_DIR/bb.out" ) &
wait
ra="$(cat "$RUN_DIR/ba.out")"; rb="$(cat "$RUN_DIR/bb.out")"
assert_ok "both claimers got a bug"     bash -c "[[ -n '$ra' && -n '$rb' ]]"
assert_ok "claimers got DIFFERENT bugs" bash -c "[[ '$ra' != '$rb' ]]"
rm -f "$CLAIMS_DIR"/bug-*.claim

# ── stale-claim recovery: clear_stale_claims frees a dead-pid bug claim, keeps a live one ──
printf 'P1 %s\n' "$$"     > "$CLAIMS_DIR/bug-6.claim"   # this shell -> live
printf 'P1 %s\n' "999999" > "$CLAIMS_DIR/bug-7.claim"   # dead pid -> stale
assert_ok "live-pid bug claim is claimed"    is_bug_claimed 6
assert_no "dead-pid bug claim is not claimed" is_bug_claimed 7
clear_stale_claims >/dev/null
assert_ok "stale bug claim swept by clear_stale_claims" bash -c "[[ ! -f '$CLAIMS_DIR/bug-7.claim' ]]"
assert_ok "live bug claim kept"                         bash -c "[[ -f '$CLAIMS_DIR/bug-6.claim' ]]"
rm -f "$CLAIMS_DIR"/bug-*.claim

# ── resident worker loop: bug_tick claims→drives→releases; pause idles; idle dedups ──
source "$HERE/../drive.sh" 2>/dev/null || true
source "$HERE/../priority-worker.sh"   # defines bug_tick/bug_step/drive_bug; main() guarded out
PRIORITY_POLL=0
DROVE="$RUN_DIR/drove"; : > "$DROVE"
drive_bug(){ echo "$1" >> "$DROVE"; }     # record which bug was driven (no real session)

# work: one claimable bug -> claim, drive, release, rc 0; claim released after the tick
_bug_numbers(){ printf '6\n'; }
bug_tick P1; assert_eq "$?" "0" "bug_tick claimed+drove a bug -> rc 0"
assert_eq "$(cat "$DROVE")" "6" "drive_bug ran for the claimed bug"
assert_ok "bug released after tick (serial: lane holds at most one)" bash -c "[[ ! -f '$CLAIMS_DIR/bug-6.claim' ]]"

# idle: no claimable bugs -> rc 1, drives nothing
: > "$DROVE"; _bug_numbers(){ :; }
bug_tick P1; assert_eq "$?" "1" "bug_tick with no bugs -> rc 1 (idle)"
assert_eq "$(cat "$DROVE")" "" "idle tick drove nothing"

# pause: bug_tick returns 3 and never claims, even with a bug available
_bug_numbers(){ printf '6\n'; }; : > "$DROVE"
touch "$PAUSE_FLAG"
bug_tick P1; assert_eq "$?" "3" "bug_tick returns 3 when paused"
assert_eq "$(cat "$DROVE")" "" "bug_tick drove nothing while paused"
assert_ok "no bug claimed while paused" bash -c "[[ -z \"\$(ls '$CLAIMS_DIR'/bug-*.claim 2>/dev/null)\" ]]"
rm -f "$PAUSE_FLAG"

# bug_step: idle banner logged ONCE per idle streak (deduped across polls), keeps polling
_bug_numbers(){ :; }; _IDLE_LOGGED=0
ILOG="$RUN_DIR/idle.log"; : > "$ILOG"
bug_step P1 >>"$ILOG" 2>&1; assert_eq "$?" "1" "bug_step: idle -> rc 1 (resident, no exit)"
bug_step P1 >>"$ILOG" 2>&1
bug_step P1 >>"$ILOG" 2>&1; assert_eq "$?" "1" "bug_step: still resident after 3 idle polls"
assert_eq "$(grep -c 'idle' "$ILOG")" "1" "bug_step: idle banner logged exactly once (deduped)"
# real work resets the dedup so a later idle streak re-announces
_bug_numbers(){ printf '6\n'; }
bug_step P1 >>"$ILOG" 2>&1; assert_eq "$?" "0" "bug_step: bug claimed+driven -> rc 0"
: > "$ILOG"; _bug_numbers(){ :; }
bug_step P1 >>"$ILOG" 2>&1; assert_eq "$?" "1" "bug_step: idle again -> rc 1"
assert_eq "$(grep -c 'idle' "$ILOG")" "1" "bug_step: idle banner re-logged after work (dedup reset)"

# ── priority.sh launches EXACTLY ONE resident lane; pid tracked under run/; idempotent ──
# Hermetic: empty HARNESS_REPO means the lane finds no bug repos and just idles (no gh).
LRUN="$(mktemp -d)"
HARNESS_PRIORITY_POLL=3600 HARNESS_TOPOLOGY=single HARNESS_REPO="" RUN_DIR="$LRUN" \
  bash "$HERE/../priority.sh" >/dev/null 2>&1
assert_ok "priority.sh wrote run/priority.pid" bash -c "[[ -f '$LRUN/priority.pid' ]]"
lpid="$(cat "$LRUN/priority.pid")"
assert_ok "lane process is alive" bash -c "kill -0 '$lpid' 2>/dev/null"
# re-run: must NOT spawn a second lane — same pid, still exactly one pidfile
HARNESS_PRIORITY_POLL=3600 HARNESS_TOPOLOGY=single HARNESS_REPO="" RUN_DIR="$LRUN" \
  bash "$HERE/../priority.sh" >/dev/null 2>&1
assert_eq "$(cat "$LRUN/priority.pid")" "$lpid" "re-run kept the same lane (idempotent, no double-spawn)"
assert_eq "$(ls "$LRUN"/priority*.pid | wc -l | tr -d ' ')" "1" "exactly one lane pidfile"
kill "$lpid" 2>/dev/null; rm -rf "$LRUN"

# ── start.sh wires the lane in alongside the pool ──
assert_ok "start.sh invokes priority.sh" bash -c "grep -q 'priority.sh' '$HERE/../start.sh'"

# ── stop.sh tears the lane down (its pidfile is generic run/*.pid) ──
SRUN="$(mktemp -d)"
( exec sleep 600 ) & lane=$!     # stand-in lane process
printf '%s\n' "$lane" > "$SRUN/priority.pid"
RUN_DIR="$SRUN" bash "$HERE/../stop.sh" >/dev/null 2>&1
assert_no "stop.sh killed the lane process"  bash -c "kill -0 '$lane' 2>/dev/null"
assert_ok "stop.sh removed the lane pidfile" bash -c "[[ ! -f '$SRUN/priority.pid' ]]"
rm -rf "$SRUN"

finish
