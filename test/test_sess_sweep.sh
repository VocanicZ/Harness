#!/usr/bin/env bash
# test_sess_sweep.sh — #418: ending a tmux lane ends what it left running. `tmux kill-session` only
# SIGHUPs the pane's process group, so a detached background job (setsid: a test server, `tail -F`,
# a watcher) outlived its lane forever, re-parented to `systemd --user`. sess_kill now also ends every
# process whose environ carries the session's HARNESS_SESSION (exactly) and the pane's whole tree, and
# stats_sweep_ended does the same for a lane that exited on its own. All on a private tmux server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
log(){ :; }
command -v tmux >/dev/null || { echo "  skip: tmux not installed"; exit 0; }
command -v setsid >/dev/null || { echo "  skip: no setsid"; exit 0; }
[[ -r /proc/self/environ ]] || { echo "  skip: no /proc"; exit 0; }
unset HARNESS_SESSION
export HARNESS_SESSION_BACKEND=tmux HARNESS_SWEEP_GRACE=1
T="$(mktemp -d)"
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE   # never the host's server
# Every pid a case starts is recorded in $T/*.pid: whatever is still up at the end is this test's to stop.
reap_all(){ local f p; for f in "$T"/*.pid; do p="$(cat "$f" 2>/dev/null)"; [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; }
trap 'tmux kill-server 2>/dev/null; reap_all; rm -rf "$T"; tmp_cleanup' EXIT
# gone <pidfile> — the process it names has exited (or is a zombie).
gone(){ ! proc_alive "$(cat "$1")"; }
up(){ proc_alive "$(cat "$1")"; }
# wait_pid_files <file>… — until every pid file is written (the pane has started its jobs).
wait_pid_files(){ local i f ok; for (( i = 0; i < 50; i++ )); do ok=1
  for f; do [[ -s $f ]] || ok=0; done; (( ok )) && return 0; sleep 0.1; done; return 1; }

U="$(new_uuid)"; O="$(new_uuid)"
cd "$T" || exit 1

echo "== sess_kill ends the session's detached jobs, its pane group and its pane tree =="
sess_start s1 "$T" -e "HARNESS_SESSION=$U" "setsid sleep 1000 & echo \$! > $T/det.pid
sleep 1001 & echo \$! > $T/grp.pid
env -u HARNESS_SESSION setsid sleep 1002 & echo \$! > $T/noenv.pid
setsid sh -c 'trap \"\" TERM; sleep 1003' & echo \$! > $T/stubborn.pid
exec sleep 999"
# Bystanders, started OUTSIDE the pane: another session's, a near-miss uuid, none, and argv naming U.
HARNESS_SESSION="$O"    setsid sleep 1100 & echo $! > "$T/other.pid"
HARNESS_SESSION="$U-x"  setsid sleep 1101 & echo $! > "$T/suffix.pid"
HARNESS_SESSION="${U%?}" setsid sleep 1102 & echo $! > "$T/prefix.pid"
setsid sleep 1103 & echo $! > "$T/none.pid"
setsid sh -c "sleep 1104; : $U" & echo $! > "$T/argv.pid"
wait_pid_files "$T/det.pid" "$T/grp.pid" "$T/noenv.pid" "$T/stubborn.pid"
sleep 0.3
assert_ok "fixture: the detached job is up before the kill" up "$T/det.pid"
assert_ok "fixture: the TERM-ignoring job is up before the kill" up "$T/stubborn.pid"
sess_kill s1; rc=$?
assert_eq "$rc" 0 "sess_kill on a live session returns 0"
sleep 0.5
assert_ok "a setsid'd job carrying the session's HARNESS_SESSION is gone"   gone "$T/det.pid"
assert_ok "a plain pane-group job is gone"                                  gone "$T/grp.pid"
assert_ok "a detached job without HARNESS_SESSION, in the pane tree, is gone" gone "$T/noenv.pid"
assert_ok "a TERM-ignoring job is KILLed after the grace period"             gone "$T/stubborn.pid"
assert_ok "another session's process survives"                              up "$T/other.pid"
assert_ok "HARNESS_SESSION=<uuid>-x survives (exact match only)"            up "$T/suffix.pid"
assert_ok "HARNESS_SESSION=<uuid prefix> survives"                          up "$T/prefix.pid"
assert_ok "a process with no HARNESS_SESSION outside the pane tree survives" up "$T/none.pid"
assert_ok "a process whose argv merely names the uuid survives"             up "$T/argv.pid"
assert_no "the session is gone" sess_live s1

echo "== sess_kill on a session that does not exist =="
sess_kill no-such 2>/dev/null; rc=$?
assert_no "returns non-zero (false when there was none)" test "$rc" -eq 0
assert_eq "$(sess_describe sess_kill =s1)" "tmux kill-session -t =s1" "sess_describe kill is unchanged"

echo "== sess_kill never kills its caller =="
# The caller's own environ names the session being killed (and so does its parent shell).
sess_start s2 "$T" -e "HARNESS_SESSION=$U" "setsid sleep 1005 & echo \$! > $T/det2.pid; exec sleep 999"
wait_pid_files "$T/det2.pid"
cat > "$T/caller.sh" <<EOF
source "$ROOT/scripts/lib.sh"; log(){ :; }
echo \$\$ > "$T/caller.pid"; echo \$PPID > "$T/callerparent.pid"
sess_kill =s2; echo "rc=\$?" > "$T/caller.rc"
proc_alive "\$PPID" && echo parent-alive >> "$T/caller.rc"
EOF
HARNESS_SESSION="$U" bash -c "bash '$T/caller.sh'; echo outer-alive >> '$T/caller.rc'"
assert_ok "the caller returned normally (rc=0)" grep -qx 'rc=0' "$T/caller.rc"
assert_ok "the caller's parent (same HARNESS_SESSION) was alive afterwards" grep -qx parent-alive "$T/caller.rc"
assert_ok "the parent shell carried on after the caller" grep -qx outer-alive "$T/caller.rc"
assert_ok "the session's detached job is still swept" gone "$T/det2.pid"

echo "== a session that exits on its own: stats_sweep_ended sweeps its leftovers =="
U3="$(new_uuid)"
sess_start s3 "$T" -e "HARNESS_SESSION=$U3" "setsid sleep 1006 & echo \$! > $T/self.pid; sleep 0.5; exit 0"
wait_pid_files "$T/self.pid"
for i in $(seq 50); do sess_live s3 || break; sleep 0.1; done
assert_no "fixture: the session closed itself" sess_live s3
HARNESS_SESSION="$U3-x" setsid sleep 1107 & echo $! > "$T/self-suffix.pid"
HARNESS_SESSION="$O" setsid sleep 1108 & echo $! > "$T/self-other.pid"
assert_ok "fixture: its detached job outlived it" up "$T/self.pid"
printf '{"session": "%s", "worktree": "%s", "tmux": "s3"}\n' "$U3" "$T" > "$RUN_DIR/s3.stats"
harness_event(){ :; }
gc_orphan_goals
sleep 0.3
assert_ok "the self-exited session's detached job is gone" gone "$T/self.pid"
assert_ok "its ctx was claimed" test ! -e "$RUN_DIR/s3.stats"
assert_ok "HARNESS_SESSION=<uuid>-x survives the self-exit sweep" up "$T/self-suffix.pid"
assert_ok "another session's process survives the self-exit sweep" up "$T/self-other.pid"
assert_ok "the earlier bystanders still survive" up "$T/none.pid"

echo "== a live session's ctx is never swept; a ctx without a uuid is not an error =="
U4="$(new_uuid)"
sess_start s4 "$T" -e "HARNESS_SESSION=$U4" "setsid sleep 1009 & echo \$! > $T/live.pid; exec sleep 999"
wait_pid_files "$T/live.pid"
printf '{"session": "%s", "tmux": "s4"}\n' "$U4" > "$RUN_DIR/s4.stats"
printf '{"tmux": "s5"}\n' > "$RUN_DIR/s5.stats"
stats_sweep_ended; rc=$?
assert_eq "$rc" 0 "stats_sweep_ended with a uuid-less ctx returns 0"
assert_ok "a live session's detached job is left alone" up "$T/live.pid"
assert_ok "a live session's ctx is kept" test -e "$RUN_DIR/s4.stats"

echo "== the headless backend sweeps an ended lane's uuid, never a live lane's (#427) =="
# A live headless lane started with U5 (a resumed lane keeps its predecessor's uuid): its runner is a
# plain process this test owns, its lane files the ones headless.sh reads.
U5="$(new_uuid)"; HL="$T/lanes"; LN="$HL/hlt-main-i5"; mkdir -p "$LN"
HARNESS_SESSION="$U5" setsid sleep 1111 & echo $! > "$T/hl-runner.pid"
HARNESS_SESSION="$U5" setsid sleep 1112 & echo $! > "$T/hl-job.pid"
HARNESS_SESSION="$O" setsid sleep 1113 & echo $! > "$T/hl-decoy.pid"
cp "$T/hl-runner.pid" "$LN/pid"; proc_ident "$(cat "$T/hl-runner.pid")" > "$LN/started"
echo "$U5" > "$LN/session"; echo '{"state": "idle"}' > "$LN/state.json"
export HARNESS_HEADLESS_DIR="$HL"
assert_ok "fixture: the lane is live" env HARNESS_SESSION_BACKEND=headless bash -c "source '$ROOT/scripts/lib.sh'; sess_live hlt-main-i5"
HARNESS_SESSION_BACKEND=headless sess_sweep "$U5"
assert_ok "headless sess_sweep leaves a live lane's processes alone" up "$T/hl-job.pid"
assert_ok "…and its runner" up "$T/hl-runner.pid"
echo '{"state": "ended"}' > "$LN/state.json"
HARNESS_SESSION_BACKEND=headless sess_sweep "$U5"
assert_ok "once the lane has ended, its leftover job is gone" gone "$T/hl-job.pid"
assert_ok "another uuid's process survives the headless sweep" up "$T/hl-decoy.pid"
HARNESS_SESSION_BACKEND=headless sess_sweep ""; assert_eq "$?" 0 "an empty uuid sweeps nothing and is not an error"
assert_ok "…the decoy is still up" up "$T/hl-decoy.pid"
unset HARNESS_HEADLESS_DIR

echo "== no pattern kill anywhere in the change =="
for f in scripts/portable.sh scripts/session/tmux.sh scripts/session/headless.sh scripts/session/dispatch.sh; do
  assert_eq "$(sed -E 's/(^|[[:space:]])#.*$//' "$ROOT/$f" | grep -nE '\b(pkill|killall|pgrep)\b')" "" "$f uses no pkill / killall / pgrep"
done

finish
