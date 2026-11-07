#!/usr/bin/env bash
# test_duplicate_workers.sh — #647: `harness start` / `start --recover` / fleet_roll / `harness status` decided "is this slot
# running?" from the pid files ALONE, so a pid file that stopped naming its live worker (overwritten, cleared as stale from another
# pid namespace, leaked by a test) made start launch a second worker beside the first — 24 orphan v0.5.0 workers ran for 40 h.
#   1. the reproduction: `start --recover` with both pid files overwritten by a dead pid leaves ONE worker per slot
#   2. a live untracked worker holding a BUG claim is not killed and no second worker is started for its slot
#   3. fleet_roll reports and stops an untracked worker (dry run changes nothing); a bug-claim holder is deferred
#   4. `status` warns about duplicate workers, and stays silent for a healthy fleet — also while a worker is mid-`$(…)` fork
#   5. a sibling fleet's worker, a `grep pool-worker.sh` and a worker's own subshell forks are never counted, adopted or killed
# The workers are real processes: stand-ins named pool-worker.sh / priority-worker.sh under the test's own engine copy, started
# with the test's own STATE_DIR. The real start.sh, pool.sh, priority.sh, roll.sh and status.sh run. No tmux, no claude, no gh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset ENGINE_DIR STATE_DIR   # a live lane exports its own; this test names every engine and fleet it runs
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/portable.sh"; source "$HERE/helpers.sh"
REAL="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
pin_host_home "$ROOT/host"
export HARNESS_EVENTS_FILE="$ROOT/events.jsonl" HARNESS_FLEETS_DIR="$ROOT/host/fleets" HARNESS_GH_RATE_GUARD=0
mkdir -p "$HARNESS_FLEETS_DIR" "$ROOT/bin"
PIDS_TO_KILL="$ROOT/pids"; : > "$PIDS_TO_KILL"
# on exit stop every worker this test started: the pids it recorded, and any a start launched into one of ITS fleets
cleanup(){ local p f
  while read -r p; do [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )) && kill "$p" 2>/dev/null; done < "$PIDS_TO_KILL"
  for f in "$ROOT"/*/.harness; do [[ -d $f ]] || continue
    while read -r p _; do [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )) && kill "$p" 2>/dev/null; done < <(fleet_worker_procs "$f"); done; }
trap cleanup EXIT

# the engine: a copy of the real scripts whose worker scripts are stand-in loops (no tmux, no claude, no gh)
ENG="$ROOT/engine"; mkdir -p "$ENG"; cp -r "$REAL/scripts" "$REAL/bin" "$REAL/prompts" "$ENG/"
[[ -f $REAL/VERSION ]] && cp "$REAL/VERSION" "$ENG/"
for w in pool priority; do
  # STUB_FORK=1: a background subshell too — what a worker's `$(…)` / `( … ) &` forks look like in the process table
  printf '#!/usr/bin/env bash\n[[ -n "${STUB_FORK:-}" ]] && { ( while :; do sleep 1; done ) & }\nwhile :; do sleep 1; done\n' > "$ENG/scripts/$w-worker.sh"
done
# a claude / gh that satisfy start.sh's prerequisite checks and do nothing else
for b in claude gh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/bin/$b"; chmod +x "$ROOT/bin/$b"; done
export PATH="$ROOT/bin:$PATH"

fleet(){ local d="$ROOT/$1/.harness"; mkdir -p "$d/run/claims" "$d/checkouts" "$ROOT/$1/proj"
  printf ': "${HARNESS_UNIT:=main}"\n: "${HARNESS_REPO:=acme/%s}"\n: "${HARNESS_POOL:=%s}"\n: "${HARNESS_SESS_PREFIX:=%s}"\n: "${HARNESS_SESSION_BACKEND:=headless}"\n: "${HARNESS_USE_POLLER:=0}"\n' "$1" "${2:-1}" "$1" > "$d/config"
  echo "$d"; }
# start <fleet> [args] — the real start.sh of the test engine against that fleet
start(){ local f="$1"; shift
  ( unset_inherited_config; cd "$(dirname "$f")/proj" && STATE_DIR="$f" ENGINE_DIR="$ENG" HARNESS_HOME="$ROOT/host" HARNESS_PREFIX_COLLISION=warn \
      HARNESS_FLEET_MIGRATE=0 bash "$ENG/scripts/start.sh" "$@" 2>&1 </dev/null ); sleep 0.3; }
# spawn <fleet> <engine dir> <pool|priority> <id> [fork] — a worker process the way pool.sh/priority.sh launch one, but named by
# NO pid file; prints its pid. (cd first, OUTSIDE the backgrounded command: `cd x && cmd &` backgrounds a wrapper subshell, and $! is it.)
spawn(){ local f="$1" eng="$2" kind="$3" id="$4"
  ( cd "$ROOT"; ENGINE_DIR="$eng" STATE_DIR="$f" STUB_FORK="${5:+1}" HARNESS_SESS_PREFIX=x nohup bash "$ENG/scripts/$kind-worker.sh" "$id" >/dev/null 2>&1 9>&- &
    echo $! > "$ROOT/last.pid" )
  sleep 0.3; cat "$ROOT/last.pid" | tee -a "$PIDS_TO_KILL"; }
stub(){ spawn "$1" "$ENG" "$2" "$3" "${4:-}"; }
alive(){ kill -0 "$1" 2>/dev/null; }
pidof_slot(){ cat "$1/run/$2.pid" 2>/dev/null; }
# nworkers <fleet> — top-level workers of that fleet in the process table
nworkers(){ ( source "$REAL/scripts/portable.sh"; fleet_worker_procs "$1" | wc -l | tr -d ' ' ); }
track(){ local p; for p in "$@"; do echo "$p" >> "$PIDS_TO_KILL"; done; }
status(){ ( unset_inherited_config; STATE_DIR="$1" ENGINE_DIR="$ENG" HARNESS_HOME="$ROOT/host" HARNESS_USE_POLLER=0 HARNESS_SESSION_BACKEND=headless \
    bash -c 'source "$ENGINE_DIR/scripts/status.sh"; duplicate_workers_report' 2>&1 ); }

echo "=== 1. start --recover with the pid files overwritten by a dead pid: one worker per slot ==="
F1="$(fleet one)"
out="$(start "$F1")"
track "$(pidof_slot "$F1" worker-1)" "$(pidof_slot "$F1" priority)"
W1="$(pidof_slot "$F1" worker-1)"; P1="$(pidof_slot "$F1" priority)"
assert_ok "plain start launched worker-1 and the priority lane" bash -c "[[ -n '$W1' && -n '$P1' ]]"
assert_eq "$(nworkers "$F1")" "2" "...two workers in the process table"
echo 999999 > "$F1/run/worker-1.pid"; echo 999999 > "$F1/run/priority.pid"   # a pid file that no longer names the live worker
out="$(start "$F1" --recover)"
echo "$out" | sed 's/^/    | /'
assert_eq "$(nworkers "$F1")" "2" "still exactly two workers for this fleet after start --recover (POOL + the priority lane)"
assert_ok "the live worker-1 is named by its pid file" bash -c "[[ '$(pidof_slot "$F1" worker-1)' == '$W1' ]]"
assert_ok "the live priority lane is named by its pid file" bash -c "[[ '$(pidof_slot "$F1" priority)' == '$P1' ]]"
assert_ok "the original worker-1 was adopted, not replaced" alive "$W1"
assert_ok "the choice is printed, with the pid" grep -q "adopted untracked worker-1 worker pid $W1" <<<"$out"
out="$(start "$F1")"
assert_eq "$(nworkers "$F1")" "2" "a plain start changes nothing"
echo "-- a worker on an older engine is stopped and replaced, not adopted"
OLD="$ROOT/engine-old"; mkdir -p "$OLD/scripts"
echo 999999 > "$F1/run/worker-1.pid"
kill "$W1"; sleep 0.3
OW="$(spawn "$F1" "$OLD" pool 1)"
out="$(start "$F1" --recover)"
assert_no "the old-engine worker was stopped" alive "$OW"
assert_ok "...and a replacement is named by the pid file" alive "$(pidof_slot "$F1" worker-1)"
assert_eq "$(nworkers "$F1")" "2" "...one worker per slot again"
assert_ok "...and the stop is printed" grep -q "stopped untracked worker-1 worker pid $OW" <<<"$out"
track "$(pidof_slot "$F1" worker-1)"

echo "=== 2. an untracked worker holding a bug claim is not killed, and its slot gets no second worker ==="
F2="$(fleet two)"
# untracked, and on an OLD engine (so it is not adoptable)
BW="$(spawn "$F2" "$OLD" pool 1)"
printf 'w1 %s bug:7 -\n' "$BW" > "$F2/run/claims/bug-acme_two-7.claim"
out="$(start "$F2" --recover)"
echo "$out" | sed 's/^/    | /'
assert_ok "the bug-claim holder is still alive" alive "$BW"
assert_eq "$(nworkers "$F2")" "2" "worker-1's slot got no second worker (the holder + the priority lane)"
assert_no "no pid file names a second worker-1" test -s "$F2/run/worker-1.pid"
assert_ok "the refusal prints the offending pid" grep -q "worker-1 NOT launched.*$BW\|pid $BW holds a bug claim" <<<"$out"
rm -f "$F2/run/claims/bug-acme_two-7.claim"
out="$(start "$F2" --recover)"
assert_no "claim released: the holder is stopped by the next start" alive "$BW"
assert_ok "...and a worker now owns the slot" alive "$(pidof_slot "$F2" worker-1)"
track "$(pidof_slot "$F2" worker-1)" "$(pidof_slot "$F2" priority)"

echo "=== 3. fleet_roll reports and stops an untracked worker ==="
F3="$(fleet three)"
start "$F3" >/dev/null; track "$(pidof_slot "$F3" worker-1)" "$(pidof_slot "$F3" priority)"
KEEP="$(pidof_slot "$F3" worker-1)"
EX="$(stub "$F3" pool 1)"                                    # a second worker-1, named by no pid file, on the current engine
assert_eq "$(nworkers "$F3")" "3" "setup: three workers (one extra)"
roll(){ ( source "$ENG/scripts/roll.sh"; export STATE_DIR="$F3"; ROLL_RESULT="$ROOT/roll.result" fleet_roll "$F3" "$ENG" "$ENG/bin/harness" "$@" ) 2>&1; }
out="$(roll 1)"
assert_ok "dry run logs the untracked worker" grep -q "would stop untracked worker-1 worker pid $EX" <<<"$out"
assert_ok "...and changes nothing" alive "$EX"
out="$(roll 0)"
assert_no "the roll stopped the untracked worker" alive "$EX"
assert_ok "...and logged it" grep -q "ACT roll: stopped untracked worker-1 worker pid $EX" <<<"$out"
assert_ok "...the tracked worker was left alone" alive "$KEEP"
assert_eq "$(awk '{print $1}' "$ROOT/roll.result")" "1" "ROLL_RESULT counts it as killed"
echo "-- a bug-claim holder is deferred"
EX2="$(stub "$F3" pool 1)"; printf 'w1 %s bug:9 -\n' "$EX2" > "$F3/run/claims/bug-acme_three-9.claim"
out="$(roll 0)"
assert_ok "the holder is alive" alive "$EX2"
assert_ok "...and the roll says so" grep -q "WARN roll: untracked worker-1 worker pid $EX2 holds a bug claim" <<<"$out"
assert_eq "$(awk '{print $2}' "$ROOT/roll.result")" "1" "ROLL_RESULT counts it as deferred"
rm -f "$F3/run/claims/bug-acme_three-9.claim"; kill "$EX2" 2>/dev/null

echo "=== 4. status warns about duplicates; a healthy fleet, even mid-fork, shows no warning ==="
F4="$(fleet four)"
start "$F4" >/dev/null; track "$(pidof_slot "$F4" worker-1)" "$(pidof_slot "$F4" priority)"
assert_eq "$(status "$F4")" "" "healthy fleet: no warning"
D4="$(stub "$F4" pool 1)"
out="$(status "$F4")"
assert_ok "an untracked worker prints the duplicate-workers warning" grep -q "duplicate workers" <<<"$out"
assert_ok "...listing its pid and slot" grep -q "pid $D4 (worker-1)" <<<"$out"
kill "$D4"; sleep 0.3
F5="$(fleet five)"
F5W="$(stub "$F5" pool 1 fork)"; echo "$F5W" > "$F5/run/worker-1.pid"          # tracked, and carrying a background subshell fork
assert_ok "setup: the worker has a subshell fork in the process table" bash -c "[[ \$(pgrep -P $F5W | wc -l) -ge 1 ]]"
assert_eq "$(nworkers "$F5")" "1" "the fork is not a worker"
assert_eq "$(status "$F5")" "" "a worker mid-fork shows no warning"
out="$(start "$F5" --recover)"
assert_eq "$(nworkers "$F5")" "2" "...and start launches no second one (the worker + the new priority lane)"
track "$(pidof_slot "$F5" priority)"
kill "$F5W" 2>/dev/null

echo "=== 5. a sibling fleet's worker, a grep and a subshell fork are never counted, adopted or killed ==="
F6="$(fleet six)"; F7="$(fleet seven)"
S7="$(stub "$F7" pool 1)"                                   # another STATE_DIR's worker
GR="$( cd "$ROOT"; STATE_DIR="$F6" nohup bash -c 'sleep 30; : grep pool-worker.sh' >/dev/null 2>&1 9>&- & echo $! )"; track "$GR"
SL="$( cd "$ROOT"; STATE_DIR="$F6" nohup sleep 30 >/dev/null 2>&1 9>&- & echo $! )"; track "$SL"
assert_eq "$(nworkers "$F6")" "0" "fleet six sees no workers of its own (a sibling's, a grep line and a sleep are not)"
out="$(start "$F6" --recover)"
track "$(pidof_slot "$F6" worker-1)" "$(pidof_slot "$F6" priority)"
assert_ok "the sibling's worker survives fleet six's start" alive "$S7"
assert_eq "$(nworkers "$F7")" "1" "...and is still the only one of fleet seven"
assert_eq "$(nworkers "$F6")" "2" "fleet six launched its own worker and lane"
assert_ok "a symlinked STATE_DIR is the same fleet (compared by realpath)" bash -c "
  ln -s '$F6' '$ROOT/six-link'; source '$REAL/scripts/portable.sh'; [[ \$(fleet_worker_procs '$ROOT/six-link' | wc -l) -eq 2 ]]"
kill "$S7" 2>/dev/null
echo "-- a worker in a slot the pool does not launch (worker-5 of POOL=1) is stopped, so the fleet stays within POOL + 1"
F8="$(fleet eight)"
ST="$(stub "$F8" pool 5)"
out="$(start "$F8")"
track "$(pidof_slot "$F8" worker-1)" "$(pidof_slot "$F8" priority)"
assert_no "the stray worker-5 was stopped" alive "$ST"
assert_eq "$(nworkers "$F8")" "2" "...POOL + the priority lane remain"

finish
