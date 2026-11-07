#!/usr/bin/env bash
# test_fleet_migrate_headless.sh — #493 / PRD #475 task 6: the headless twin of the tmux parts of
# test_fleet_migrate.sh (#467 / #537 / #566): the `if command -v tmux` blocks of the `harness update` roll and
# the #566 `harness start` case. scripts/fleet-migrate.sh rolls a fleet's workers onto the new engine and NEVER
# touches a lane session: here the lanes are real headless lanes (HARNESS_SESSION_BACKEND=headless: detached
# runners of scripts/cli/claude_headless.py started through launch_agent against the fake claude of
# test/fixtures/cli/claude/stream-json/), so it needs no tmux and runs on native Windows. Asserted of each lane:
# the runner is the same live process, in the same state, having started no new turn and no second claude
# (LANESNAP). The fixtures, the stub `harness` and the stand-in workers are the minimum copied from
# test_fleet_migrate.sh; the migration / roll assertions that test makes about configs, pids and start calls stay
# there.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
unset STATE_DIR   # (#537) `fleet-migrate.sh --all` falls back to the live fleet's STATE_DIR when a lane runs this directly
ENGINE="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
pin_host_home "$ROOT/host"
export HARNESS_EVENTS_FILE="$ROOT/events.jsonl" HARNESS_SESSION_BACKEND=headless
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
source "$ENGINE/scripts/session/dispatch.sh"   # sess_* on the headless backend (lanes live under $HARNESS_HOME/lanes)

# Only the processes this test started: each lane's runner (its pid file), each fake claude (calls.jsonl), the
# stand-in workers (their pid files) and the bystander. Never a pattern kill: the host runs other lanes.
BYSTANDER=""
our_pids(){ local d; shopt -s nullglob
  for d in "$ROOT"/host/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$ROOT"/fake-*/; do python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null; done
  for d in "$ROOT"/*/.harness/run/; do cat "$d"/worker-*.pid "$d"/priority.pid 2>/dev/null; done
  shopt -u nullglob; echo "$BYSTANDER"; }
kill_ours(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; return 0; }
trap 'kill_ours; tmp_cleanup' EXIT

# fleet <name> <config body> [targets.tsv body] [checkout dirs…] — a fixture project; prints its .harness dir
fleet(){ local name="$1" cfg="$2" tsv="${3:-}" d="$ROOT/$1/.harness"; shift 3 2>/dev/null || shift $#
  mkdir -p "$d/run" "$d/checkouts" "$d/worktrees"
  printf '%s\n' "$cfg" > "$d/config"
  [[ -n "$tsv" ]] && printf '%b' "$tsv" > "$d/targets.tsv"
  local c; for c in "$@"; do mkdir -p "$d/checkouts/$c/.git"; done
  echo "$d"; }
read_cfg(){ ( unset_inherited_config; export STATE_DIR="$1" HARNESS_HOME="$ROOT/host" HARNESS_GH_RATE_GUARD=0
    unset TARGETS_TSV RUN_DIR; source "$ENGINE/scripts/lib.sh" >/dev/null 2>&1; eval "$2" ); }

# ── the stub engine and the stand-in workers (copied from test_fleet_migrate.sh) ──────────────────
STUB="$ROOT/engine"; mkdir -p "$STUB/bin" "$STUB/scripts"
cp "$ENGINE"/scripts/{fleet-migrate.sh,fleet_migrate.py,stats.py,portable.sh,roll.sh} "$STUB/scripts/"
START_LOG="$ROOT/start.log"; : > "$START_LOG"
cat > "$STUB/bin/harness" <<'STUBEOF'
#!/usr/bin/env bash
# stand-in for `harness start`: record the call, launch stand-in workers.
[[ "$1" == --state-dir && "$3" == start ]] || exit 9
d="$2"; pool="$(sed -n 's/^.*HARNESS_POOL[:=]*\([0-9]*\).*$/\1/p' "$d/config" | head -n1)"
echo "start $d pool=$pool" >> "$START_LOG"
for ((i = 1; i <= pool; i++)); do nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$d/run/worker-$i.pid"; done
nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$d/run/priority.pid"
STUBEOF
chmod +x "$STUB/bin/harness"; export START_LOG

UA="$(fleet upd-a ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_REPO:=acme/a}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_CAP:=3}"
: "${HARNESS_SESS_PREFIX:=ua}"' 'alpha\tacme/a\t-\tA\n' a)"
UD="$(fleet upd-d ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/d}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_SESS_PREFIX:=ud}"')"       # registered, already one repo (rc 10), workers on an OLD release (#537)
mkdir -p "$ROOT/host/fleets"; export HARNESS_FLEETS_DIR="$ROOT/host/fleets"
for p in "$UA" "$UD"; do
  printf '{"prefix": "x", "project": "%s", "run_dir": "%s/run", "slugs": [], "started_at": 1}' "$p" "$p" > "$ROOT/host/fleets/$(basename "$(dirname "$p")").json"
done
spawn(){ nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$1"; }
OLDENG="$ROOT/engine-old"; mkdir -p "$OLDENG"      # an older release dir: any dir that is not the engine under test
spawn_eng(){ ENGINE_DIR="$2" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$1"; }
spawn "$UA/run/worker-1.pid"; spawn "$UA/run/priority.pid"
spawn_eng "$UD/run/worker-1.pid" "$OLDENG"; spawn_eng "$UD/run/priority.pid" "$OLDENG"
pidsof(){ cat "$1"/run/worker-*.pid "$1"/run/priority.pid 2>/dev/null | tr '\n' ' '; }
OLD_A="$(pidsof "$UA")"; OLD_D="$(pidsof "$UD")"
alive(){ local p; for p in $1; do proc_alive "$p" || return 1; done; }
dead(){ local p; for p in $1; do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
nohup sleep 600 >/dev/null 2>&1 9>&- & BYSTANDER=$!; disown "$BYSTANDER" 2>/dev/null

# ── headless lanes: a fleet's lane, another fleet's, and a bystander session ───────────────────────
# mklane <session> <start dir> — a real headless lane started by launch_agent; its start directory is what
# attributes it to its fleet. The fake claude takes the bootstrap turn and the lane settles idle.
mklane(){ local s="$1" wd="$2" fk="$ROOT/fake-$1" prefix="${1%%-*}"
  mkdir -p "$wd" "$fk" "$ROOT/lane-state/.harness"; echo "the task" > "$wd/.harness-task.md"; echo normal > "$fk/plan"
  ( export STATE_DIR="$ROOT/lane-state/.harness" HARNESS_SESS_PREFIX="$prefix" FAKE_CLAUDE_DIR="$fk" HARNESS_CLI=claude \
           HARNESS_CLAUDE_BIN="python3 $(native_path "$FAKE")" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
    source "$ENGINE/scripts/lib.sh" >/dev/null 2>&1
    GOAL=ISSUE:1 PROMISE="ISSUE 1 DONE" MAXITER=10 launch_agent "$s" "$wd" >"$ROOT/lane-$s.out" 2>&1 )
  wait_until 20 bash -c "[[ \"\$(python3 '$ENGINE/scripts/cli/claude_headless.py' state --lane '$ROOT/host/lanes/$s' --field state 2>/dev/null)\" == idle ]]"; }
LANEPID(){ sess_pane_pid "$1"; }
# LANESNAP <session> — everything that says the lane was neither killed, relaunched nor driven: the runner's pid,
# its state word, the turns it has started, the claude processes it has run, its start directory.
LANESNAP(){ echo "pid=$(LANEPID "$1") state=$(sess_state "$1") turns=$(sess_turns "$1") claudes=$(wc -l < "$ROOT/fake-$1/calls.jsonl" 2>/dev/null | tr -d ' ') dir=$(sess_list_paths | grep "^$1	")"; }
# lane_survived <session> <snapshot> <label>
lane_survived(){ local s="$1" want="$2" what="$3" p; p="${want#pid=}"; p="${p%% *}"
  assert_ok "$what: its runner process is alive" alive "$p"
  assert_ok "$what: the lane is still live" sess_live "$s"
  assert_eq "$(LANESNAP "$s")" "$want" "$what: the same runner, state, turns, claude count and start directory (neither killed nor relaunched)"; }
mklane ua-alpha-i5 "$UA/worktrees/alpha-i5"; mklane ud-main-i3 "$UD/worktrees/main-i3"; mklane other-session "$ROOT/other/wd"
# #643: adoption only takes a lane whose worktree is a git worktree on issue/<N> holding its task file
git init -q "$UD/worktrees/main-i3"; git -C "$UD/worktrees/main-i3" symbolic-ref HEAD refs/heads/issue/3
SNAP_A="$(LANESNAP ua-alpha-i5)"; SNAP_D="$(LANESNAP ud-main-i3)"; SNAP_O="$(LANESNAP other-session)"
assert_eq "$(sess_list | sort | tr '\n' ' ')" "other-session ua-alpha-i5 ud-main-i3 " "setup: the three headless lanes are live"
assert_ok "setup: each is a detached runner" test "$(sess_panes | grep -c ' headless$')" = 3

# ── harness update's roll: fleet-migrate.sh --all, with the lanes live ─────────────────────────────
out="$( ENGINE_DIR="$STUB" HARNESS_HOME="$ROOT/host" bash "$STUB/scripts/fleet-migrate.sh" --all 2>&1)"
assert_ok "update: fleet A is migrated"                    grep -q 'HARNESS_UNIT:=alpha' "$UA/config"
assert_ok "update: A's old worker + priority pids are dead" dead "$OLD_A"
assert_ok "update: an already-migrated (rc 10) fleet's old-release workers are killed (#537)" dead "$OLD_D"
assert_ok "update: ...and relaunched"                      alive "$(pidsof "$UD")"
assert_ok "update: the bystander process is untouched"     kill -0 "$BYSTANDER"
lane_survived ua-alpha-i5 "$SNAP_A" "update: the fleet's live lane"
lane_survived other-session "$SNAP_O" "update: another fleet's / a bystander lane"
lane_survived ud-main-i3 "$SNAP_D" "update: an rc-10 fleet's live lane survives its roll (#537)"
# ...and the relaunched worker adopts it: the REAL adopt_lanes, run as that fleet's worker, writes the claim.
adopted="$( unset_inherited_config; export STATE_DIR="$UD" HARNESS_GH_RATE_GUARD=0 HARNESS_SESSION_BACKEND=headless HARNESS_UNIT=main HARNESS_SESS_PREFIX=ud
  unset TARGETS_TSV RUN_DIR; source "$ENGINE/scripts/lib.sh" >/dev/null 2>&1; source "$ENGINE/scripts/drive.sh" >/dev/null 2>&1
  _HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1; source "$ENGINE/scripts/pool-worker.sh" >/dev/null 2>&1
  mkdir -p "$CLAIMS_DIR"
  as_worker(){ local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx; adopt_lanes W7; }; as_worker >/dev/null 2>&1; cat "$CLAIMS_DIR/impl-3.claim" 2>/dev/null )"
assert_ok "update: ...the relaunched worker adopts the rolled fleet's headless lane (adopt_lanes writes impl-3.claim, #537)" grep -q '^W7 [0-9]* IMPL:3 ud-main-i3 ' <<<"$adopted"
rpid="${SNAP_D#pid=}"; rpid="${rpid%% *}"
assert_eq "$(awk '{print $5}' <<<"$adopted")" "$rpid" "update: ...the claim records the lane's runner pid"
lane_survived ud-main-i3 "$SNAP_D" "update: ...and adopting it leaves the lane as it was"

# ── #566: `harness start` on an already-migrated fleet stops its old-engine workers, never the lane ─
SA="$(fleet start-oldw ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/o}"
: "${HARNESS_POOL:=2}"
: "${HARNESS_CAP:=1}"
: "${HARNESS_SESS_PREFIX:=hzso}"
: "${HARNESS_CLAUDE_BIN:=/nonexistent/claude}"')"
spawn_eng "$SA/run/worker-1.pid" "$OLDENG"; spawn_eng "$SA/run/priority.pid" "$OLDENG"; spawn_eng "$SA/run/worker-2.pid" "$OLDENG"
OLD_SA="$(pidsof "$SA")"
mklane hzso-main-i9 "$SA/worktrees/main-i9"; SNAP_S="$(LANESNAP hzso-main-i9)"
# the lanes live under the same HARNESS_HOME start.sh runs with, so a start that touched a lane session would reach it
# (only the fleet / poller registries are kept apart from the roll's above)
( unset_inherited_config; export HARNESS_SESSION_BACKEND=headless HARNESS_HOME="$ROOT/host" HARNESS_FLEETS_DIR="$ROOT/host2/fleets" HARNESS_POLLER_DIR="$ROOT/host2/poller" HARNESS_SNAPSHOTS_DIR="$ROOT/host2/snapshots"
  STATE_DIR="$SA" ENGINE_DIR="$ENGINE" bash "$ENGINE/scripts/start.sh" >"$ROOT/start-sa.out" 2>&1 )
assert_no "start #566: the leftover HARNESS_CAP line is gone"        grep -q HARNESS_CAP "$SA/config"
assert_ok "start #566: ...the old-engine workers and priority lane are stopped" dead "$OLD_SA"
lane_survived hzso-main-i9 "$SNAP_S" "start #566: ...with the fleet's headless lane"
lane_survived ua-alpha-i5 "$SNAP_A" "start #566: ...and the other fleets' lanes"
lane_survived ud-main-i3 "$SNAP_D" "start #566: ...(rc-10 fleet's too)"
lane_survived other-session "$SNAP_O" "start #566: ...(and the bystander's)"

finish
