#!/usr/bin/env bash
# test_supervise_autoupdate_headless.sh — #493 / PRD #475 task 6: the headless twin of
# test_supervise_autoupdate.sh (#477). `harness supervise` installs a published release by itself and
# rolls every fleet's workers onto it, without killing a lane — here on HARNESS_SESSION_BACKEND=headless,
# so it needs no tmux and runs on native Windows. The fleets' lane sessions are real headless lanes
# (detached runners of scripts/cli/claude_headless.py, started through launch_agent against the fake
# claude of test/fixtures/cli/claude/stream-json/): one fleet's lane idle, the other's mid-turn (a
# `hang` turn). Everything the tmux test asserts about a lane session surviving is asserted of those
# lanes: the same runner process (identity-checked by sess_pane_pid), still live, in the same state,
# having started no new turn and launched no second claude, still attributed to its fleet by its start
# directory. The release install / worker roll assertions are repeated as they are what the roll is
# about. Real release layout (release_fixture.sh, file:// "GitHub"), real `harness start` / pool.sh /
# priority.sh against stub worker scripts, a stub gh / systemctl. Nothing here touches the network or a
# real fleet.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_UNDER_TEST="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
unset_inherited_config   # a lane running this directly must not lend the fleets under test its own prefix
T="$(mktemp -d)"; tmp_track "$T"
# Only the processes this test started: each lane's runner (its pid file) and each fake claude (calls.jsonl /
# pids). Never a pattern kill: the host runs other lanes.
our_pids(){ local d; shopt -s nullglob
  for d in "$H"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$T"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
    [[ -f "$d/pids" ]] && tr ' ' '\n' < "$d/pids"
  done; shopt -u nullglob; }
kill_ours(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; return 0; }
trap 'kill_ours; tmp_cleanup' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
pin_host_home "$T/host"   # + the fleet/poller/snapshot pins, unit dirs and user bus (#541)
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units"
export HARNESS_SUPERVISE_LOGINCTL=true HARNESS_WEB_SYSTEMCTL=true HARNESS_WEB_LOGINCTL=true HARNESS_GH_RATE_GUARD=0
export HARNESS_SUPERVISE_SYSTEMCTL="$T/bin/systemctl"
export HARNESS_SUPERVISE_GLOB="$T/none/*" HARNESS_SUPERVISE_CONF="$T/none.conf"
export ONLINE_URL=file:///etc/hostname HARNESS_AUTO_UPDATE_EVERY=0 HARNESS_AUTO_UPDATE_HEALTH_S=2
export HARNESS_AGY_BIN="$T/bin/agy" HARNESS_RELEASE_REPO=VocanicZ/Harness
export HARNESS_SESSION_BACKEND=headless   # every lane below is a headless runner: no tmux anywhere
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"; EV="$H/events.jsonl"; SLOG="$H/supervise.log"
mkdir -p "$T/bin"
# stubs: a claude/agy/rtdd that does nothing, a gh that logs every call, systemctl that can kill the supervisor
for b in claude agy rtdd; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$b"; done
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$T/gh.calls" >"$T/bin/gh"
cat >"$T/bin/systemctl" <<EOF
#!/bin/sh
# KILL_SUP: when set, a unit restart kills the supervisor that is running the update (#477).
case "\$*" in *restart*) [ -f "$T/kill-sup" ] && kill -9 "\$(cat "$T/kill-sup")" 2>/dev/null; echo restart >>"$T/systemctl.calls";; esac
exit 0
EOF
chmod +x "$T"/bin/*; export PATH="$T/bin:$PATH"

# The engine the "releases" ship: THIS checkout, with the workers replaced by stubs that just sleep
# (GOOD) or die at once (BAD). start.sh, pool.sh, priority.sh, supervise.sh are the real ones.
mk_src(){ local d="$1" mode="$2" w; rm -rf "$d"; mkdir -p "$d"
  ( cd "$FIXTURE_ENGINE_SRC" && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$d"
  for w in pool-worker priority-worker; do
    if [[ $mode == bad ]]; then printf '#!/usr/bin/env bash\nexit 1\n' >"$d/scripts/$w.sh"
    else printf '#!/usr/bin/env bash\nexec sleep 600\n' >"$d/scripts/$w.sh"; fi
  done; }
REAL_SRC="$FIXTURE_ENGINE_SRC"
mk_src "$T/src-good" good; mk_src "$T/src-bad" bad
FIXTURE_ENGINE_SRC="$REAL_SRC"   # mk_src reads the checkout; rel_publish below reads whichever it is pointed at
pub(){ FIXTURE_ENGINE_SRC="$T/src-$2"; rel_publish "$SRV" "$1"; FIXTURE_ENGINE_SRC="$REAL_SRC"; }

source "$ENGINE_UNDER_TEST/scripts/session/dispatch.sh"   # sess_* on the headless backend, for the assertions
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
hrn(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$H/engine/bin/harness" "$@"; }
# (#537) update.sh now rolls every registered fleet itself (fleet-migrate --all), so a supervisor-installed release
# would arrive with its workers already rolled and nothing left for the SUPERVISOR's roll — the thing under test here.
# HARNESS_FLEET_MIGRATE=0 skips update.sh's roll; test_fleet_migrate.sh covers that one.
sup(){ HARNESS_FLEET_MIGRATE=0 hrn supervise --once "$@" >>"$T/sup.out" 2>&1; }
sup_n(){ local n; n="$(grep -c "$1" "$SLOG" 2>/dev/null)"; echo "${n:-0}"; }
ev_n(){ local n; n="$(grep -c "\"event\": *\"$1\"" "$EV" 2>/dev/null)"; echo "${n:-0}"; }
tag_of(){ readlink "$H/engine"; }
pidof_f(){ cat "$1" 2>/dev/null; }
eng_of(){ local e; e="$(tr '\0' '\n' </proc/$1/environ 2>/dev/null | sed -n 's/^ENGINE_DIR=//p')"; realpath -m "$e" 2>/dev/null; }
alive(){ proc_alive "$1"; }
alive_all(){ local p; for p in $1; do proc_alive "$p" || return 1; done; }
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }

# mklane <fleet> <idle|busy> — the fleet's lane <fleet>-main-i1 as a real headless lane, started by launch_agent in the
# worktree whose path attributes the session to its fleet. idle: the bootstrap turn ends and the lane waits at its
# prompt; busy: the turn is a `hang` (never ends), so the lane is mid-turn, its claude and a grandchild running.
mklane(){ local f="$1" kind="$2" st="$T/fleets/$1/proj/.harness" wd="$T/fleets/$1/proj/.harness/worktrees/main-i1" fk="$T/fake-$1"
  mkdir -p "$wd" "$fk"; echo "the task" > "$wd/.harness-task.md"; rm -f "$fk/calls.jsonl" "$fk/pids"
  if [[ $kind == busy ]]; then echo hang > "$fk/plan"; else echo normal > "$fk/plan"; fi
  ( export STATE_DIR="$st" FAKE_CLAUDE_DIR="$fk" HARNESS_CLI=claude HARNESS_CLAUDE_BIN="python3 $(native_path "$FAKE")" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
    source "$ENGINE_UNDER_TEST/scripts/lib.sh" >/dev/null 2>&1
    GOAL=ISSUE:1 PROMISE="ISSUE 1 DONE" MAXITER=10 launch_agent "$f-main-i1" "$wd" >"$T/lane-$f.out" 2>&1 ); }
lane_settled(){ local f="$1" s="$f-main-i1"
  if [[ $2 == busy ]]; then [[ "$(sess_state "$s")" == busy && -s "$T/fake-$f/pids" ]]; else [[ "$(sess_state "$s")" == idle ]]; fi; }
LANE(){ echo "$1-main-i1"; }
LANEPID(){ sess_pane_pid "$(LANE "$1")"; }
LANECALLS(){ wc -l < "$T/fake-$1/calls.jsonl" 2>/dev/null | tr -d ' '; }
FAKEPIDS(){ cat "$T/fake-$1/pids" 2>/dev/null | tr '\n' ' '; }
# LANESNAP <fleet> — everything that says the lane was neither killed, relaunched nor driven: the runner's pid, its
# state word, the turns it has started, the claude processes it has run, its start directory.
LANESNAP(){ local s; s="$(LANE "$1")"
  echo "pid=$(LANEPID "$1") state=$(sess_state "$s") turns=$(sess_turns "$s") claudes=$(LANECALLS "$1") dir=$(sess_list_paths | grep "^$s	")"; }
# lane_survived <fleet> <snapshot> <label> — the headless counterpart of "the lane session is neither killed nor relaunched".
lane_survived(){ local f="$1" want="$2" what="$3" s p
  s="$(LANE "$f")"; p="${want#pid=}"; p="${p%% *}"
  assert_eq "$(LANEPID "$f")" "$p" "$what: the lane's runner is the same process (neither killed nor relaunched)"
  assert_ok "$what: the lane's runner process is alive" alive "$p"
  assert_ok "$what: the lane is still live" sess_live "$s"
  assert_eq "$(LANESNAP "$f")" "$want" "$what: the lane's state, turns, claude count and start directory are unchanged"
  if [[ -s "$T/fake-$f/pids" ]]; then assert_ok "$what: its mid-turn claude and grandchild are still running" alive_all "$(FAKEPIDS "$f")"; fi; }
# fresh_host <initial tag> — a host on <tag>, two fleets started on it, one headless lane each (fa idle, fb mid-turn).
fresh_host(){ local tag="$1" f i
  kill_ours; tmp_kill_rooted "$H" "$T/fleets"; rm -rf "$H" "$T/fleets" "$T/units" "$T/gh.calls" "$T/kill-sup" "$T/sup.out" "$T/systemctl.calls"
  mkdir -p "$H" "$T/units"; : >"$T/gh.calls"
  rel_install_at "$SRV" "$tag"
  i=0; for f in fa fb; do i=$((i+1)); mkdir -p "$T/fleets/$f/proj/.harness"
    ( cd "$T/fleets/$f/proj" && git init -q . )
    printf ': "${HARNESS_MODE:=single}"\n: "${HARNESS_REPO:=o/%s}"\n: "${HARNESS_SESS_PREFIX:=%s}"\n: "${HARNESS_POOL:=1}"\n: "${HARNESS_USE_POLLER:=0}"\n: "${HARNESS_SESSION_BACKEND:=headless}"\n' "$f" "$f" >"$T/fleets/$f/proj/.harness/config"
    hrn --state-dir "$T/fleets/$f/proj/.harness" start >"$T/start-$f.out" 2>&1
    # the lane's start directory is what attributes the session to its fleet
    if [[ $f == fa ]]; then mklane "$f" idle; else mklane "$f" busy; fi
    wait_until 20 lane_settled "$f" "$([[ $f == fa ]] && echo idle || echo busy)"
  done
  sleep 0.3; }
RUN(){ echo "$T/fleets/$1/proj/.harness/run"; }

echo "=== setup: a host on v0.1.0, v0.2.0 published ==="
pub v0.1.0 good; pub v0.2.0 good; rel_latest "$SRV" v0.2.0
fresh_host v0.1.0
for f in fa fb; do
  assert_ok "$f: worker-1 up on v0.1.0" alive "$(pidof_f "$(RUN $f)/worker-1.pid")"
  assert_eq "$(eng_of "$(pidof_f "$(RUN $f)/worker-1.pid")")" "$(realpath "$H/releases/v0.1.0")" "$f: worker runs from releases/v0.1.0"
  assert_ok "$f: its headless lane is up (a detached runner, not a tmux pane)" sess_live "$(LANE $f)"
done
assert_eq "$(sess_state "$(LANE fa)")" idle "fa: the lane is idle at its prompt"
assert_eq "$(sess_state "$(LANE fb)")" busy "fb: the lane is mid-turn"

echo "=== #477: one pass installs the release and rolls every fleet, lanes untouched ==="
old_a=$(pidof_f "$(RUN fa)/worker-1.pid"); old_pa=$(pidof_f "$(RUN fa)/priority.pid")
old_b=$(pidof_f "$(RUN fb)/worker-1.pid"); old_pb=$(pidof_f "$(RUN fb)/priority.pid")
lane_a=$(LANESNAP fa); lane_b=$(LANESNAP fb)
sup
assert_eq "$(tag_of)" releases/v0.2.0 "the engine link points at the published release"
for f in fa fb; do
  w=$(pidof_f "$(RUN $f)/worker-1.pid"); p=$(pidof_f "$(RUN $f)/priority.pid")
  assert_ok "$f: worker is alive" alive "$w"
  assert_ok "$f: priority is alive" alive "$p"
  assert_eq "$(eng_of "$w")" "$(realpath "$H/releases/v0.2.0")" "$f: the worker runs from releases/v0.2.0"
  assert_eq "$(eng_of "$p")" "$(realpath "$H/releases/v0.2.0")" "$f: the priority lane runs from releases/v0.2.0"
done
assert_no "fa: the old worker process is gone"   alive "$old_a"
assert_no "fa: the old priority process is gone" alive "$old_pa"
assert_no "fb: the old worker process is gone"   alive "$old_b"
assert_no "fb: the old priority process is gone" alive "$old_pb"
lane_survived fa "$lane_a" "fa"
lane_survived fb "$lane_b" "fb"
assert_eq "$(ev_n engine_updated)" 1 "engine_updated is emitted once"
assert_eq "$(ev_n workers_rolled)" 2 "workers_rolled is emitted once per fleet"
assert_ok "engine_updated names from and to" grep -qE '"event": *"engine_updated".*"from": *"v0.1.0".*"to": *"v0.2.0"|"event": *"engine_updated".*"to": *"v0.2.0".*"from": *"v0.1.0"' "$EV"
sup
assert_eq "$(ev_n engine_updated)" 1 "a second pass does not install it again"
assert_eq "$(ev_n workers_rolled)" 2 "a second pass rolls nothing more"
lane_survived fa "$lane_a" "after a second pass: fa"
lane_survived fb "$lane_b" "after a second pass: fb"

echo "=== a released worker is rolled even when the pass finds the same tag current ==="
old_a=$(pidof_f "$(RUN fa)/worker-1.pid"); sup
assert_eq "$(pidof_f "$(RUN fa)/worker-1.pid")" "$old_a" "workers already on the new release are left alone"

echo "=== bug-claim deferral ==="
rel_latest "$SRV" v0.1.0   # nothing newer
fresh_host v0.1.0; rel_latest "$SRV" v0.2.0
prio=$(pidof_f "$(RUN fa)/priority.pid"); w1=$(pidof_f "$(RUN fa)/worker-1.pid")
printf 'P1 %s o/fa#5\n' "$prio" >"$(RUN fa)/claims/bug-o_fa-5.claim"
sup
assert_eq "$(pidof_f "$(RUN fa)/priority.pid")" "$prio" "a priority worker holding a bug claim is not killed"
assert_ok "…and is still alive" alive "$prio"
assert_no "the idle worker beside it is rolled" alive "$w1"
assert_eq "$(eng_of "$(pidof_f "$(RUN fa)/worker-1.pid")")" "$(realpath "$H/releases/v0.2.0")" "…onto the new release"
assert_eq "$(eng_of "$(pidof_f "$(RUN fb)/priority.pid")")" "$(realpath "$H/releases/v0.2.0")" "the other fleet is rolled in full"
assert_ok "the deferral is in the event" grep -qE '"deferred": *1' "$EV"
rm -f "$(RUN fa)/claims/bug-o_fa-5.claim"
sup
assert_no "the claim released: the next pass rolls the priority worker" alive "$prio"
assert_eq "$(eng_of "$(pidof_f "$(RUN fa)/priority.pid")")" "$(realpath "$H/releases/v0.2.0")" "…onto the new release"

echo "=== a paused fleet is rolled too, and stays paused ==="
rel_latest "$SRV" v0.1.0; fresh_host v0.1.0; rel_latest "$SRV" v0.2.0
touch "$(RUN fa)/PAUSED"; old_a=$(pidof_f "$(RUN fa)/worker-1.pid")
sup
assert_no "the paused fleet's old worker is gone" alive "$old_a"
assert_eq "$(eng_of "$(pidof_f "$(RUN fa)/worker-1.pid")")" "$(realpath "$H/releases/v0.2.0")" "…its new one runs the new release"
assert_ok "the fleet is still paused" test -f "$(RUN fa)/PAUSED"

echo "=== a fleet stopped on purpose (no worker pid files) is skipped ==="
rel_latest "$SRV" v0.1.0; fresh_host v0.1.0; rel_latest "$SRV" v0.2.0
rm -f "$(RUN fb)"/*.pid
sup
assert_eq "$(ls "$(RUN fb)"/*.pid 2>/dev/null | wc -l)" 0 "a stopped fleet is not started"
assert_eq "$(ev_n workers_rolled)" 1 "only the live fleet is rolled"

echo "=== opt-outs: nothing is queried, installed or killed ==="
nothing_happens(){ local why="$1" w; w=$(pidof_f "$(RUN fa)/worker-1.pid")
  assert_eq "$(tag_of)" releases/v0.1.0 "$why: the engine is unchanged"
  assert_eq "$(pidof_f "$(RUN fa)/worker-1.pid")" "$w" "$why: no worker is killed"
  assert_eq "$(ev_n engine_updated)" 0 "$why: no engine_updated"; }
rel_latest "$SRV" v0.1.0; fresh_host v0.1.0; rel_latest "$SRV" v0.2.0
rm -f "$SRV/latest.json"; : >"$SLOG"                       # a query now would be a WARN: the API is gone
HARNESS_AUTO_UPDATE=0 sup
nothing_happens "HARNESS_AUTO_UPDATE=0"
assert_eq "$(sup_n 'auto-update')" 0 "HARNESS_AUTO_UPDATE=0: not even a release query (no log line)"
rel_latest "$SRV" v0.2.0
HARNESS_REF=v0.2.0 sup;                nothing_happens "a HARNESS_REF pin"
rel_latest "$SRV" v0.1.0; sup;         nothing_happens "an equal published tag"
rel_latest "$SRV" v0.0.9; sup;         nothing_happens "an older published tag"
rel_latest "$SRV" nightly; : >"$SLOG"; sup; nothing_happens "an unparseable tag"
assert_ok "an unparseable tag is logged" grep -q 'nightly' "$SLOG"
rel_latest "$SRV" v0.2.0
# a dev clone (ENGINE_DIR is not a release of this host) is left alone
( cd "$T" && env -u STATE_DIR -u HARNESS_ENGINE_LINK ENGINE_DIR="$REAL_SRC" bash "$REAL_SRC/scripts/supervise.sh" --once >>"$T/sup.out" 2>&1 )
nothing_happens "a dev clone's supervisor"
# a git-checkout engine (a real directory with .git) is left alone
mv "$H/engine" "$T/engine.link"; cp -r "$H/releases/v0.1.0" "$H/engine"; mkdir "$H/engine/.git"
sup; assert_ok "a git-checkout engine stays a directory" test -d "$H/engine" ; assert_no "…and is not replaced by a release" test -L "$H/engine"
assert_eq "$(ls "$H/releases")" "v0.1.0" "…nothing was installed beside it"
rm -rf "$H/engine"; mv "$T/engine.link" "$H/engine"

echo "=== throttle: HARNESS_AUTO_UPDATE_EVERY ==="
fresh_host v0.1.0; rel_latest "$SRV" v0.1.0
HARNESS_AUTO_UPDATE_EVERY=600 sup                     # stamps the check
rel_latest "$SRV" v0.2.0
HARNESS_AUTO_UPDATE_EVERY=600 sup
assert_eq "$(tag_of)" releases/v0.1.0 "inside the interval the release is not queried again"
HARNESS_AUTO_UPDATE_EVERY=0 sup
assert_eq "$(tag_of)" releases/v0.2.0 "once the interval has elapsed it is installed"

echo "=== offline and a failed query ==="
fresh_host v0.1.0; rel_latest "$SRV" v0.2.0; : >"$SLOG"
ONLINE_URL=file:///nonexistent sup
assert_eq "$(tag_of)" releases/v0.1.0 "offline: nothing is installed"
rm -f "$SRV/latest.json"; sup
assert_eq "$(tag_of)" releases/v0.1.0 "an unreachable release API installs nothing"
assert_eq "$(sup_n 'WARN auto-update')" 1 "…and logs one WARN"

echo "=== --dry-run logs the update and the roll, and does neither ==="
rel_latest "$SRV" v0.2.0; : >"$SLOG"; w=$(pidof_f "$(RUN fa)/worker-1.pid")
sup --dry-run
assert_eq "$(tag_of)" releases/v0.1.0 "dry run: the engine is unchanged"
assert_ok "dry run: the worker is alive" alive "$w"
assert_ok "dry run: the would-be update is logged" grep -q 'DRY auto-update: would update v0.1.0 -> v0.2.0' "$SLOG"
assert_no "dry run: no state is written" test -e "$H/supervise/auto-update.json"
# …and the roll half: really install, then dry-run the roll
fresh_host v0.1.0; rel_latest "$SRV" v0.2.0; w=$(pidof_f "$(RUN fa)/worker-1.pid")
HARNESS_FLEET_MIGRATE=0 hrn update >/dev/null 2>&1   # an operator updated by hand, roll skipped (#537: update rolls by default): every worker is still on v0.1.0
mkdir -p "$H/supervise"; printf '{"tag":"v0.2.0","prev":"v0.1.0","phase":"rolling","roll_done":0,"health":"pending","flipped_at":%s,"rolled_at":""}\n' "$(date +%s)" >"$H/supervise/auto-update.json"
: >"$SLOG"; sup --dry-run
assert_ok "dry run: the worker is still alive" alive "$w"
assert_ok "dry run: the would-be kill is logged" grep -q 'DRY auto-update: would kill' "$SLOG"

echo "=== rollback: the relaunched workers die ==="
rm -rf "$SRV"; rel_server "$SRV"; pub v0.1.0 good; pub v0.2.0 bad; rel_latest "$SRV" v0.2.0
fresh_host v0.1.0
lane_a=$(LANESNAP fa); lane_b=$(LANESNAP fb)
sup                                                    # install v0.2.0, roll: the new workers exit 1 at once
assert_eq "$(tag_of)" releases/v0.2.0 "the bad release was installed"
sleep 3                                                # HARNESS_AUTO_UPDATE_HEALTH_S=2
sup                                                    # health check: dead pids → rollback
assert_eq "$(tag_of)" releases/v0.1.0 "the engine points at the old tag again"
for f in fa fb; do
  assert_ok "$f: the worker was relaunched and lives" alive "$(pidof_f "$(RUN $f)/worker-1.pid")"
  assert_eq "$(eng_of "$(pidof_f "$(RUN $f)/worker-1.pid")")" "$(realpath "$H/releases/v0.1.0")" "$f: the worker runs the old release again"
  assert_eq "$(eng_of "$(pidof_f "$(RUN $f)/priority.pid")")" "$(realpath "$H/releases/v0.1.0")" "$f: the priority lane too"
done
assert_eq "$(grep -c 'issue create' "$T/gh.calls")" 1 "exactly one bug is filed"
assert_ok "…on the engine's own repo, labelled bug" grep -q 'issue create -R VocanicZ/Harness --label bug' "$T/gh.calls"
assert_ok "…naming the bad tag" grep -q 'v0.2.0' "$T/gh.calls"
assert_ok "…and the release it rolled back to" grep -q 'v0.1.0' "$T/gh.calls"
assert_ok "…and the dead pid files" grep -q 'worker-1.pid' "$T/gh.calls"
assert_eq "$(ev_n engine_rolled_back)" 1 "engine_rolled_back is emitted"
lane_survived fa "$lane_a" "the update and the rollback: fa"
lane_survived fb "$lane_b" "the update and the rollback: fb"
sup
assert_eq "$(tag_of)" releases/v0.1.0 "a later pass with the same tag still latest does not install it again"
assert_eq "$(grep -c 'issue create' "$T/gh.calls")" 1 "…and files no second bug"
pub v0.3.0 good; rel_latest "$SRV" v0.3.0
sup
assert_eq "$(tag_of)" releases/v0.3.0 "a NEWER tag is still installed"
assert_eq "$(eng_of "$(pidof_f "$(RUN fa)/worker-1.pid")")" "$(realpath "$H/releases/v0.3.0")" "…and the workers roll onto it"

echo "=== the update restarts the supervisor mid-way: the next one finishes the roll ==="
rm -rf "$SRV"; rel_server "$SRV"; pub v0.1.0 good; pub v0.2.0 good; rel_latest "$SRV" v0.2.0
fresh_host v0.1.0
hrn supervise --install >/dev/null 2>&1                # the unit the update will find and "restart"
assert_ok "the supervise unit is installed" test -f "$T/units/harness-supervise.service"
old_a=$(pidof_f "$(RUN fa)/worker-1.pid"); lane_a=$(LANESNAP fa); lane_b=$(LANESNAP fb)
( exec env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK HARNESS_FLEET_MIGRATE=0 bash "$H/engine/bin/harness" supervise --once >>"$T/sup.out" 2>&1 ) &   # (#537) update.sh would roll the fleets itself; this models an update that died before it
echo $! >"$T/kill-sup"        # the exec'd supervisor itself: the unit restart kills it, as systemd would
for _ in $(seq 1 100); do grep -q 'Update complete' "$SLOG" 2>/dev/null && break; sleep 0.2; done
sleep 0.5
assert_ok "the unit restart killed the supervisor mid-update" test -s "$T/systemctl.calls"
assert_eq "$(tag_of)" releases/v0.2.0 "the update still flipped the engine"
assert_ok "the old worker had not been rolled yet" alive "$old_a"
rm -f "$T/kill-sup"
sup
assert_no "the next supervisor rolls the old worker" alive "$old_a"
assert_eq "$(eng_of "$(pidof_f "$(RUN fa)/worker-1.pid")")" "$(realpath "$H/releases/v0.2.0")" "…onto the new release"
assert_eq "$(eng_of "$(pidof_f "$(RUN fb)/priority.pid")")" "$(realpath "$H/releases/v0.2.0")" "…in every fleet"
assert_eq "$(ev_n engine_updated)" 1 "engine_updated is emitted once across the two supervisors"
lane_survived fa "$lane_a" "the restarted-supervisor roll: fa"
lane_survived fb "$lane_b" "the restarted-supervisor roll: fb"
sleep 3; sup
assert_ok "the health check ran from the on-disk state" grep -q '"health": *"ok"' "$H/supervise/auto-update.json"

finish
