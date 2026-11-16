#!/usr/bin/env bash
# test_poller_roll.sh — #1204: the host poller rolls onto the current engine, exits when its engine is
# gone, and a worker whose snapshot gate keeps failing restarts a live-but-useless poller (rate-limited).
# Hermetic: HARNESS_POLLER_CMD stands in for the loop (a `sleep` carrying the caller's exported ENGINE_DIR),
# two bare engine dirs A/ and B/ stand in for releases, and the host root is a temp dir.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
source "$HERE/helpers.sh"
pin_host_home "$WORK/host"
export HARNESS_POLLER_DIR="$WORK/host/poller"
export HARNESS_SNAPSHOTS_DIR="$WORK/host/snapshots"
export STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
export HARNESS_POLLER_CMD="sleep 120"

source "$HERE/../scripts/lib.sh"
REAL_ENGINE="$ENGINE_DIR"
A="$WORK/releases/A"; B="$WORK/releases/B"
mkdir -p "$A/scripts" "$B/scripts" "$HARNESS_HOME"

# from <engine> <fn…> — run a function as a process whose ENGINE_DIR is <engine> (a worker of that release).
from(){ local e="$1"; shift; ( ENGINE_DIR="$e"; export ENGINE_DIR; "$@" ); }
pid_now(){ cat "$POLLER_PID" 2>/dev/null; }
alive(){ kill -0 "$1" 2>/dev/null && [[ "$(proc_state "$1")" != Z ]]; }
engine_of(){ local i e; for i in 1 2 3 4 5 6 7 8 9 10; do e="$(proc_env "$1" ENGINE_DIR)"; [[ -n $e ]] && break; sleep 0.1; done; printf '%s\n' "$e"; }   # environ reads empty for an instant while the child execs
reset_poller(){ local p; p="$(pid_now)"; [[ "$p" =~ ^[0-9]+$ && $p -gt 1 ]] && kill "$p" 2>/dev/null; sleep 0.2; rm -f "$POLLER_PID" "$HARNESS_POLLER_DIR"/escalate.ts; }

# ── 1) engine mismatch rolls the poller ──────────────────────────────────────
ln -sfn "$B" "$HARNESS_HOME/engine"
rm -f "$POLLER_PID"
from "$A" ensure_poller
pA="$(pid_now)"
assert_eq "$(engine_of "$pA")" "$A" "poller launched by a release-A caller carries ENGINE_DIR=A"
from "$B" ensure_poller
pB="$(pid_now)"
assert_ok "current-engine caller replaced the poller (new pid)" test -n "$pB" -a "$pB" != "$pA"
assert_no "the old A poller was stopped" alive "$pA"
assert_ok "the new poller is alive" alive "$pB"
assert_eq "$(engine_of "$pB")" "$B" "new poller runs from ENGINE_DIR=B"

# ── 2) no ping-pong: a caller still on A leaves the B poller alone ───────────
from "$A" ensure_poller
assert_eq "$(pid_now)" "$pB" "caller on a non-current release leaves the current-engine poller untouched"
reset_poller
from "$A" ensure_poller; p0="$(pid_now)"; relaunches=0; last="$p0"
for e in "$B" "$A" "$B" "$A" "$B"; do
  from "$e" ensure_poller
  [[ "$(pid_now)" != "$last" ]] && { relaunches=$((relaunches+1)); last="$(pid_now)"; }
done
assert_eq "$relaunches" "1" "alternating A/B callers relaunch the poller exactly once"
assert_eq "$(engine_of "$(pid_now)")" "$B" "…and it ended on the current engine"

# ── 3) idempotent when matching ──────────────────────────────────────────────
p1="$(pid_now)"; from "$B" ensure_poller; from "$B" ensure_poller
assert_eq "$(pid_now)" "$p1" "poller already on the caller's current engine is not respawned"
reset_poller

# ── 4) a gone engine is always replaced, even with no $HARNESS_HOME/engine link ──
rm -f "$HARNESS_HOME/engine"
A2="$WORK/releases/A2"; mkdir -p "$A2/scripts"
from "$A2" ensure_poller; pg="$(pid_now)"
from "$B" ensure_poller
assert_eq "$(pid_now)" "$pg" "no engine link, poller's engine exists, caller differs: left alone (dev clones, tests)"
rm -rf "$A2"
from "$B" ensure_poller
assert_ok "engine dir deleted: poller relaunched" test "$(pid_now)" != "$pg"
assert_no "the orphaned poller was stopped" alive "$pg"
assert_eq "$(engine_of "$(pid_now)")" "$B" "relaunched from the caller's engine"
reset_poller
ln -sfn "$B" "$HARNESS_HOME/engine"
A3="$WORK/releases/A3"; mkdir -p "$A3/scripts"
from "$A3" ensure_poller; pg="$(pid_now)"; rm -rf "$A3"
from "$A" ensure_poller
assert_ok "engine gone: a caller that is NOT the current engine replaces it too" test "$(pid_now)" != "$pg"
reset_poller

# ── 5) poller.sh loop exits when its engine goes away ────────────────────────
C="$WORK/releases/C"; mkdir -p "$C"; cp -r "$REAL_ENGINE/scripts" "$C/scripts"
[[ -d "$REAL_ENGINE/prompts" ]] && cp -r "$REAL_ENGINE/prompts" "$C/prompts"
poller_register acme/widget 1 hz "$WORK/projA/.harness"
mkdir -p "$WORK/projA/.harness"
( unset HARNESS_POLLER_CMD; ENGINE_DIR="$C" HARNESS_PRIORITY_POLL=1 bash "$C/scripts/poller.sh" >"$WORK/loop.out" 2>&1 & echo $! > "$WORK/loop.pid" )
for _ in $(seq 1 50); do [[ -s "$POLLER_PID" ]] && break; sleep 0.1; done
lp="$(cat "$WORK/loop.pid")"
assert_ok "looping poller.sh is up" alive "$lp"
rm -rf "$C/scripts"
for _ in $(seq 1 60); do alive "$lp" || break; sleep 0.1; done
assert_no "poller.sh exited once its engine's scripts/ was removed" alive "$lp"
assert_ok "it logged why" grep -q "engine .* is gone" "$WORK/loop.out"
assert_no "it removed poller.pid" test -e "$POLLER_PID"
poller_deregister "$WORK/projA/.harness"

# ── 6) worker backstop: snapshot_gate failing while the poller lives ─────────
export HARNESS_REPO="acme/widget" HARNESS_OWNER=acme HARNESS_POLLER_ESCALATE_TICKS=3 HARNESS_POLLER_ESCALATE_S=300
poller_register acme/widget 60 hz "$WORK/projA/.harness"
rm -f "$HARNESS_SNAPSHOTS_DIR"/*.json
ENGINE_DIR="$B"; export ENGINE_DIR
ln -sfn "$B" "$HARNESS_HOME/engine"
ensure_poller; ps0="$(pid_now)"
old_pid_file(){ touch -d '1 hour ago' "$POLLER_PID"; }
old_pid_file
GATE="$WORK/gate.out"; : > "$GATE"
snapshot_gate >>"$GATE"; snapshot_gate >>"$GATE"
assert_eq "$(pid_now)" "$ps0" "2 failing ticks: below the threshold, poller untouched"
snapshot_gate >>"$GATE"; rc=$?
assert_ok "gate still reports stale (holds dispatch)" test "$rc" -ne 0
ps1="$(pid_now)"
assert_ok "3rd consecutive failing tick restarted the poller" test "$ps1" != "$ps0"
assert_no "the old poller pid was stopped" alive "$ps0"
assert_ok "restart logged on its own line" grep -q "snapshot stale for 3 ticks.*restarting poller" "$GATE"
for _ in 1 2 3 4 5 6; do snapshot_gate >>"$GATE"; done
assert_eq "$(pid_now)" "$ps1" "no second restart inside the escalation window"
old_pid_file
for _ in 1 2 3 4 5 6; do snapshot_gate >>"$GATE"; done
assert_eq "$(pid_now)" "$ps1" "…even with an old pidfile: the timestamp file holds the window"
rm -f "$HARNESS_POLLER_DIR/escalate.ts"; old_pid_file
gh_rate_held(){ echo $(( $(date +%s) + 100 )); }   # the token is rate-limited: the poller is legitimately parked
for _ in 1 2 3 4 5 6; do snapshot_gate >>"$GATE"; done
assert_eq "$(pid_now)" "$ps1" "no restart while the poller waits out a GitHub rate limit"
unset -f gh_rate_held; source "$HERE/../scripts/ghrate.sh"
# a poller launched moments ago is never judged stale
rm -f "$HARNESS_POLLER_DIR/escalate.ts"; touch "$POLLER_PID"
for _ in 1 2 3 4 5 6; do snapshot_gate >>"$GATE"; done
assert_eq "$(pid_now)" "$ps1" "a freshly launched poller gets time to write its first snapshot"
reset_poller
poller_deregister "$WORK/projA/.harness"

# ── 7) kill safety: garbage poller.pid never reaches kill ────────────────────
KILLS=()
kill(){ KILLS+=("$*"); builtin kill "$@"; }
for junk in "" "abc" "0" "1" "-1" " " "12abc" "00" "1 2"; do
  printf '%s\n' "$junk" > "$POLLER_PID"
  KILLS=()
  poller_running && alive_rc=up || alive_rc=down
  assert_eq "$alive_rc" "down" "poller_running: pid file [$junk] is no live poller"
  _poller_stop
  assert_eq "${#KILLS[@]}" "0" "_poller_stop with pid file [$junk] signals nothing"
done
printf '' > "$POLLER_PID"; KILLS=()
from "$B" ensure_poller
assert_eq "${#KILLS[@]}" "0" "ensure_poller over an empty pid file launches without signalling anything"
unset -f kill
reset_poller

rm -rf "$WORK"
finish
