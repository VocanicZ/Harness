#!/usr/bin/env bash
# test_sess_sweep_headless.sh — #493 / PRD #475 task 6: the headless twin of test_sess_sweep.sh (#418).
# Ending a lane ends what it left running: sess_kill also ends every process whose environ carries the lane's
# HARNESS_SESSION exactly, and the lane's whole process tree; stats_sweep_ended does the same for a lane that
# exited on its own; a detached (setsid) background job must not outlive the lane; a process of a
# similarly-named session (prefix / suffix / another uuid) is never killed. The same assertions, on the
# HEADLESS session backend (HARNESS_SESSION_BACKEND=headless): the lanes are detached runner processes
# (scripts/cli/claude_headless.py) driving the fake claude of test/fixtures/cli/claude/stream-json/, whose
# turn-hook leaves the jobs a real agent turn would. No tmux anywhere, so it runs where the tmux test cannot
# (native Windows / Git Bash). Only pids this test started are signalled — never a pattern kill.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
_DOCTOR_SOURCED=1 source "$ROOT/scripts/doctor.sh"
make_env
[[ -r /proc/self/environ ]] || { echo "  skip: no /proc"; exit 0; }   # the sweep reads each process's environ
unset HARNESS_SESSION
export RUN_DIR HARNESS_SESS_PREFIX=hsw HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude HARNESS_SWEEP_GRACE=1
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $(native_path "$FAKE")" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_STALL_RETRIES=3 HARNESS_LIMIT_NUDGE_EVERY=1 HARNESS_INTERRUPT_WAIT=10 HARNESS_HEADLESS_STOP_WAIT=10
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }
limit_checkpoint_once(){ :; }   # its mechanical checkpoint commits and comments on GitHub (usage.sh)
T="$RUN_DIR/pids"; mkdir -p "$T"
SS="$(detach_prefix)"   # setsid where the host has it (empty on Git Bash: a native child is detached anyway)

# Every pid a case starts is recorded in $T/*.pid (or a lane's pid / the fake's calls.jsonl and pids): whatever
# is still up at the end is this test's to stop. Never a pattern kill: the host runs other lanes.
our_pids(){ local d f; shopt -s nullglob
  for f in "$T"/*.pid "$RUN_DIR"/fake-*/*.pid; do cat "$f" 2>/dev/null; echo; done
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
    [[ -f "$d/pids" ]] && tr ' ' '\n' < "$d/pids"
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
gone(){ ! proc_alive "$(cat "$1")"; }
up(){ proc_alive "$(cat "$1")"; }
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
# wait_pid_files <file>… — until every pid file is written (the turn has started its jobs).
wait_pid_files(){ local i f ok; for (( i = 0; i < 100; i++ )); do ok=1
  for f; do [[ -s $f ]] || ok=0; done; (( ok )) && return 0; sleep 0.1; done; return 1; }
# lane <name> <plan…> — a worktree and a fake-claude dir replaying <plan> (one fixture per turn).
lane(){ local name="$1"; shift
  WD="$RUN_DIR/wd-$name"; mkdir -p "$WD"; echo "the task" > "$WD/.harness-task.md"
  export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$name"; mkdir -p "$FAKE_CLAUDE_DIR"
  printf '%s\n' "$@" > "$FAKE_CLAUDE_DIR/plan"; }
# jobs_hook <tag> — the lane's turn-hook (it runs in the turn's cwd and environment, as the commands an agent
# runs would): the jobs test_sess_sweep.sh starts in its pane. det: a setsid'd job (a session of its own,
# carrying the lane's HARNESS_SESSION); grp: a plain background job in the turn's process group; noenv: a job
# in the turn's tree that does not carry the session; stubborn: a setsid'd job that ignores TERM.
jobs_hook(){ local t="$1" d="$FAKE_CLAUDE_DIR"
  cat > "$d/turn-hook" <<EOF
#!/usr/bin/env bash
$SS sleep 1000 </dev/null >/dev/null 2>&1 & echo \$! > "$T/$t-det.pid"
sleep 1001 </dev/null >/dev/null 2>&1 & echo \$! > "$T/$t-grp.pid"
env -u HARNESS_SESSION sleep 1002 </dev/null >/dev/null 2>&1 & echo \$! > "$T/$t-noenv.pid"
$SS sh -c 'trap "" TERM; sleep 1003' </dev/null >/dev/null 2>&1 & echo \$! > "$T/$t-stubborn.pid"
EOF
  chmod +x "$d/turn-hook"; }
launch(){ GOAL="ISSUE:$2" MAXITER=10 PROMISE="ISSUE $2 DONE" launch_agent "$1" "$WD" >/dev/null 2>&1; }
lane_uuid(){ cat "$(headless_lane_dir "$1")/session" 2>/dev/null; }
lane_state(){ python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$1")" --field "$2" 2>/dev/null; }
# turn_ended <sess> <n> — the lane has ended its <n>th turn and is idle.
turn_ended(){ [[ "$(lane_state "$1" turn)" == "$2" && "$(lane_state "$1" state)" == idle ]]; }
# bystanders <tag> <uuid> <other uuid> — processes started OUTSIDE the lane: another session's, a near-miss
# uuid on each side, none, and argv naming the uuid.
bystanders(){ local t="$1" u="$2" o="$3"
  HARNESS_SESSION="$o"     $SS sleep 1100 </dev/null >/dev/null 2>&1 & echo $! > "$T/$t-other.pid"; disown "$!" 2>/dev/null
  HARNESS_SESSION="$u-x"   $SS sleep 1101 </dev/null >/dev/null 2>&1 & echo $! > "$T/$t-suffix.pid"; disown "$!" 2>/dev/null
  HARNESS_SESSION="${u%?}" $SS sleep 1102 </dev/null >/dev/null 2>&1 & echo $! > "$T/$t-prefix.pid"; disown "$!" 2>/dev/null
  $SS sleep 1103 </dev/null >/dev/null 2>&1 & echo $! > "$T/$t-none.pid"; disown "$!" 2>/dev/null
  $SS sh -c "sleep 1104; : $u" </dev/null >/dev/null 2>&1 & echo $! > "$T/$t-argv.pid"; disown; }
O="$(new_uuid)"
cd "$RUN_DIR" || exit 1

echo "== sess_kill ends the lane's detached jobs, its turn's group and its process tree =="
# A turn that is still running (it hangs, with a grandchild) when the lane is killed.
S=hsw-main-i1; lane i1 hang; jobs_hook a
launch "$S" 1; rc=$?
assert_eq "$rc" 0 "launch_agent starts the lane"
assert_ok "fixture: the lane is live" sess_live "$S"
U="$(lane_uuid "$S")"
assert_ok "fixture: the lane carries a HARNESS_SESSION" test -n "$U"
bystanders a "$U" "$O"
wait_pid_files "$T/a-det.pid" "$T/a-grp.pid" "$T/a-noenv.pid" "$T/a-stubborn.pid" "$FAKE_CLAUDE_DIR/pids"
sleep 0.3
read -r fpid gpid < "$FAKE_CLAUDE_DIR/pids"; rpid="$(sess_pane_pid "$S")"
assert_ok "fixture: the lane's own process is the runner, up" proc_alive "$rpid"
assert_eq "$(proc_env "$rpid" HARNESS_SESSION)" "$U" "fixture: the runner's environ carries the lane's HARNESS_SESSION"
assert_ok "fixture: the detached job is up before the kill" up "$T/a-det.pid"
assert_ok "fixture: the TERM-ignoring job is up before the kill" up "$T/a-stubborn.pid"
assert_eq "$(proc_env "$(cat "$T/a-det.pid")" HARNESS_SESSION)" "$U" "fixture: the detached job inherited the lane's HARNESS_SESSION"
sess_kill "$S"; rc=$?
assert_eq "$rc" 0 "sess_kill on a live session returns 0"
sleep 0.5
assert_ok "a setsid'd job carrying the session's HARNESS_SESSION is gone"   gone "$T/a-det.pid"
assert_ok "a plain turn-group job is gone"                                  gone "$T/a-grp.pid"
assert_ok "a job without HARNESS_SESSION, in the turn's tree, is gone"      gone "$T/a-noenv.pid"
assert_ok "a TERM-ignoring job is KILLed after the grace period"            gone "$T/a-stubborn.pid"
assert_no "the runner is gone" proc_alive "$rpid"
assert_no "the running turn is gone" proc_alive "$fpid"
assert_no "…and so is its own child" proc_alive "$gpid"
assert_ok "another session's process survives"                              up "$T/a-other.pid"
assert_ok "HARNESS_SESSION=<uuid>-x survives (exact match only)"            up "$T/a-suffix.pid"
assert_ok "HARNESS_SESSION=<uuid prefix> survives"                          up "$T/a-prefix.pid"
assert_ok "a process with no HARNESS_SESSION outside the lane's tree survives" up "$T/a-none.pid"
assert_ok "a process whose argv merely names the uuid survives"             up "$T/a-argv.pid"
assert_no "the session is gone" sess_live "$S"

echo "== …and when the turn ended normally and left its jobs behind (no process group reaches them) =="
S=hsw-main-i2; lane i2 normal; jobs_hook b
launch "$S" 2
assert_ok "the turn ends, the lane idle" wait_until 20 turn_ended "$S" 1
U2="$(lane_uuid "$S")"
wait_pid_files "$T/b-det.pid" "$T/b-stubborn.pid"
sleep 0.3
assert_ok "fixture: the detached job outlived its turn" up "$T/b-det.pid"
assert_ok "fixture: the TERM-ignoring job outlived its turn" up "$T/b-stubborn.pid"
sess_kill "$S"; rc=$?
assert_eq "$rc" 0 "sess_kill on the idle lane returns 0"
sleep 0.5
assert_ok "the detached job left behind by an ended turn is gone" gone "$T/b-det.pid"
assert_ok "a TERM-ignoring leftover is KILLed after the grace period" gone "$T/b-stubborn.pid"
assert_ok "another session's process still survives"            up "$T/a-other.pid"
assert_ok "HARNESS_SESSION=<uuid>-x still survives"             up "$T/a-suffix.pid"
assert_ok "a process with no HARNESS_SESSION still survives"    up "$T/a-none.pid"
assert_no "the session is gone" sess_live "$S"

echo "== sess_kill on a session that does not exist =="
sess_kill no-such 2>/dev/null; rc=$?
assert_no "returns non-zero (false when there was none)" test "$rc" -eq 0
assert_eq "$(sess_describe sess_kill =s1)" "headless stop =s1" "sess_describe kill names the headless stop"

echo "== sess_kill never kills its caller =="
# The caller's own environ names the session being killed (and so does its parent shell).
S=hsw-main-i3; lane i3 normal; jobs_hook c
launch "$S" 3
assert_ok "the turn ends, the lane idle" wait_until 20 turn_ended "$S" 1
U3="$(lane_uuid "$S")"
wait_pid_files "$T/c-det.pid"
cat > "$T/caller.sh" <<EOF
source "$ROOT/scripts/lib.sh"; log(){ :; }
echo \$\$ > "$T/caller.pid"; echo \$PPID > "$T/callerparent.pid"
sess_kill =$S; echo "rc=\$?" > "$T/caller.rc"
proc_alive "\$PPID" && echo parent-alive >> "$T/caller.rc"
EOF
HARNESS_SESSION="$U3" bash -c "bash '$T/caller.sh'; echo outer-alive >> '$T/caller.rc'"
assert_ok "the caller returned normally (rc=0)" grep -qx 'rc=0' "$T/caller.rc"
assert_ok "the caller's parent (same HARNESS_SESSION) was alive afterwards" grep -qx parent-alive "$T/caller.rc"
assert_ok "the parent shell carried on after the caller" grep -qx outer-alive "$T/caller.rc"
assert_ok "the session's detached job is still swept" gone "$T/c-det.pid"
assert_no "the lane is gone" sess_live "$S"

echo "== a lane that exits on its own: stats_sweep_ended sweeps its leftovers =="
S=hsw-main-i4; lane i4 normal; jobs_hook d
launch "$S" 4
assert_ok "the turn ends, the lane idle" wait_until 20 turn_ended "$S" 1
U4="$(lane_uuid "$S")"
wait_pid_files "$T/d-det.pid" "$T/d-stubborn.pid"
python3 "$ROOT/scripts/cli/headless_core.py" stop --lane "$(headless_lane_dir "$S")" >/dev/null 2>&1   # the runner ends itself
lane_over(){ ! sess_live "$1"; }
wait_until 15 lane_over "$S"
assert_no "fixture: the session is not live" sess_live "$S"
HARNESS_SESSION="$U4-x" $SS sleep 1107 </dev/null >/dev/null 2>&1 & echo $! > "$T/self-suffix.pid"; disown; disown "$!" 2>/dev/null
HARNESS_SESSION="$O"    $SS sleep 1108 </dev/null >/dev/null 2>&1 & echo $! > "$T/self-other.pid"; disown; disown "$!" 2>/dev/null
assert_ok "fixture: its detached job outlived it" up "$T/d-det.pid"
assert_ok "fixture: its ctx is waiting to be swept" test -e "$RUN_DIR/$S.stats"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session"))' "$RUN_DIR/$S.stats")" "$U4" "fixture: …and names the lane's uuid"
stats_sweep_ended
sleep 0.3
assert_ok "the self-exited lane's detached job is gone" gone "$T/d-det.pid"
assert_ok "…and its TERM-ignoring one" gone "$T/d-stubborn.pid"
assert_ok "its ctx was claimed" test ! -e "$RUN_DIR/$S.stats"
assert_ok "HARNESS_SESSION=<uuid>-x survives the self-exit sweep" up "$T/self-suffix.pid"
assert_ok "another session's process survives the self-exit sweep" up "$T/self-other.pid"
assert_ok "the earlier bystanders still survive" up "$T/a-none.pid"

echo "== a live lane's ctx is never swept; a ctx without a uuid is not an error =="
S=hsw-main-i5; lane i5 normal; jobs_hook e
launch "$S" 5
assert_ok "the turn ends, the lane idle" wait_until 20 turn_ended "$S" 1
U5="$(lane_uuid "$S")"
wait_pid_files "$T/e-det.pid"
printf '{"tmux": "hsw-main-i6"}\n' > "$RUN_DIR/hsw-main-i6.stats"
stats_sweep_ended; rc=$?
assert_eq "$rc" 0 "stats_sweep_ended with a uuid-less ctx returns 0"
assert_ok "a live lane's detached job is left alone" up "$T/e-det.pid"
assert_ok "a live lane's ctx is kept" test -e "$RUN_DIR/$S.stats"

echo "== sess_sweep: a live lane's uuid sweeps nothing, an ended lane's sweeps its leftovers (#427) =="
sess_sweep "$U5"
assert_ok "sess_sweep leaves a live lane's detached job alone" up "$T/e-det.pid"
assert_ok "…and its runner" proc_alive "$(sess_pane_pid "$S")"
python3 "$ROOT/scripts/cli/headless_core.py" stop --lane "$(headless_lane_dir "$S")" >/dev/null 2>&1
wait_until 15 lane_over "$S"
assert_no "fixture: the lane has ended" sess_live "$S"
assert_ok "fixture: its job outlived it" up "$T/e-det.pid"
sess_sweep ""; assert_eq "$?" 0 "an empty uuid sweeps nothing and is not an error"
assert_ok "…the leftover is still up" up "$T/e-det.pid"
assert_ok "…and the decoy is too" up "$T/a-other.pid"
sess_sweep "$U5"
assert_ok "once the lane has ended, its leftover job is gone" gone "$T/e-det.pid"
assert_ok "another uuid's process survives the sweep" up "$T/a-other.pid"
assert_ok "HARNESS_SESSION=<uuid>-x of the first lane survives" up "$T/a-suffix.pid"

echo "== no pattern kill anywhere in the change =="
for f in scripts/portable.sh scripts/session/tmux.sh scripts/session/headless.sh scripts/session/dispatch.sh; do
  assert_eq "$(sed -E 's/(^|[[:space:]])#.*$//' "$ROOT/$f" | grep -nE '\b(pkill|killall|pgrep)\b')" "" "$f uses no pkill / killall / pgrep"
done

finish
