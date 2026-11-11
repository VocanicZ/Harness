#!/usr/bin/env bash
# harness-test-timeout-windows: 3600
# test_winsma.sh — the winsma helpers (#479, PRD #475) on Linux: a fake ssh that runs the remote script locally,
# a fake C: drive, a fake Task Scheduler, a fake process list. Covers HARNESS_WINDOWS_HOST, the lock (taken,
# waiter waits on a live heartbeat, the stale breaker needs old heartbeat AND a gone owner lane), isolation,
# the guard (changed file, new Harness\* task, ~/.claude.json inside vs outside C:\hx-<issue>), the credential
# scan, cleanup, and the whole `run` sequence. Nothing here touches a real Windows host.
set -uo pipefail
rc=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
W="$HERE/smoke/winsma"
TOK="ghp_TESTTOKEN0123456789abcdefghijklmnop"

# fresh_env — a new fake machine under a tracked temp dir, every knob pointed at it.
fresh_env(){ local d; d="$(mktemp -d)"; tmp_track "$d"; T="$d"
  mkdir -p "$T/c" "$T/home/.claude/skills" "$T/home/.claude/plugins" "$T/home/.local/bin" "$T/home/.harness" "$T/bin"
  echo '{"theme":"dark"}' >"$T/home/.claude/settings.json"; echo '[user]' >"$T/home/.gitconfig"
  echo '{"plugins":{}}' >"$T/home/.claude/plugins/installed_plugins.json"; echo '{}' >"$T/home/.claude/plugins/known_marketplaces.json"
  echo 'harness' >"$T/home/.local/bin/harness"; echo 'v0.1.1' >"$T/home/.harness/version"
  echo '{"numStartups":1,"projects":{"C:\\Users\\pc\\work":{"lastCost":1.5},"C:\\hx-smoke":{"x":1}}}' >"$T/home/.claude.json"
  printf '#!/usr/bin/env bash\nexec bash -s\n' >"$T/bin/fakessh"
  cat >"$T/bin/schtasks" <<'S'
#!/usr/bin/env bash
db="$FAKE_TASKS"; touch "$db"; echo "$*" >>"$db.log"; op="$1"; tn=""
while [ $# -gt 0 ]; do [ "$1" = //TN ] && tn="$2"; shift; done
case "$op" in
  //Create) echo "$tn" >>"$db";;
  //Delete) grep -vxF "$tn" "$db" >"$db.n"; mv "$db.n" "$db";;
  //Query) while read -r t; do printf '"\\%s","N/A","Ready"\r\n' "$t"; done <"$db";;
esac
S
  printf '#!/usr/bin/env bash\nnohup bash "$1" >/dev/null 2>&1 </dev/null &\necho $!\n' >"$T/bin/spawn"
  cat >"$T/bin/procs" <<'S'
#!/usr/bin/env bash
for p in $(cat "$FAKE_PROCS.$1" 2>/dev/null); do s="$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)"; [ -n "$s" ] && [ "$s" != Z ] && echo "$p"; done; true
S
  chmod +x "$T/bin/"*
  export WS_C="$T/c" HOME="$T/home" HX_REAL_HOME="$T/home" WINSMA_SSH="$T/bin/fakessh" WS_SCHTASKS="$T/bin/schtasks" \
    WS_SPAWN="$T/bin/spawn" WS_PROCS_CMD="$T/bin/procs" WS_KILL=kill WS_PYTHON=python3 WS_VENV_ARGS=--without-pip WS_HB_INTERVAL=1 \
    FAKE_TASKS="$T/tasks.db" FAKE_PROCS="$T/procs" HARNESS_WINDOWS_HOST=winsma-fake GH_TOKEN="$TOK" \
    WS_POLL_MIN=0 WS_POLL=0.2 WS_LOCK_TIMEOUT=0 WS_STALE_SEC=1800 TEMP="$T/temp" TMP="$T/temp" GH_CONFIG_DIR="$T/home/ghcfg"
  mkdir -p "$T/temp" "$T/home/ghcfg"; echo 'hosts' >"$T/home/ghcfg/hosts.yml"
  unset WS_OWNER_LIVE_CMD WS_LANE_PID WS_LANE_SESSION WS_LOG
  source "$W/winsma.sh"; }
# seed_lock <issue> <session> <pid> <age_seconds> — someone else's lock, with a heartbeat that old.
seed_lock(){ ws_call r_lock_take "$1" "$2" "$3" >/dev/null; echo $(( $(date +%s) - $4 )) >"$WS_C/hx-lock/heartbeat"; }
alive(){ kill -0 "$1" 2>/dev/null; }

echo "# HARNESS_WINDOWS_HOST"
( fresh_env; unset HARNESS_WINDOWS_HOST
  assert_no "no host configured: winsma.sh host fails" bash "$W/winsma.sh" host
  assert_eq "$(bash "$W/winsma.sh" lock 5 2>&1 | tail -1)" "winsma: HARNESS_WINDOWS_HOST is not set: there is no Windows host to run on" "unset: lock refuses and says why"
  assert_eq "$(HARNESS_WINDOWS_HOST=fromenv bash "$W/winsma.sh" host)" "fromenv" "set in the environment: read"
  grep -q 'HARNESS_WINDOWS_HOST:=' "$HERE/../scripts/lib.sh"; assert_eq "$?" "0" "lib.sh defaults the key (empty), like every config key"
  mkdir -p "$T/p/.harness"; echo ': "${HARNESS_WINDOWS_HOST:=fromconfig}"' >"$T/p/.harness/config"
  assert_eq "$(STATE_DIR="$T/p/.harness" bash "$W/winsma.sh" host)" "fromconfig" "set in .harness/config: read through lib.sh"
  assert_eq "$(HARNESS_WINDOWS_HOST=fromenv STATE_DIR="$T/p/.harness" bash "$W/winsma.sh" host)" "fromenv" "the environment beats the config file"
  grep -q '`HARNESS_WINDOWS_HOST`' "$HERE/../docs/reference.md"; assert_eq "$?" "0" "docs/reference.md documents the key"
  finish ) || rc=1

echo "# lock"
( fresh_env
  ws_lock 479 lane-a $$ >/dev/null; rc=$?
  assert_eq "$rc" "0" "an unheld lock is taken"
  assert_eq "$(cat "$WS_C/hx-lock/owner")" "$(printf 'issue=479\nsession=lane-a\nhost_pid=%s' $$)" "owner = issue, lane session, claude-host pid"
  assert_ok "heartbeat written" test -s "$WS_C/hx-lock/heartbeat"
  hbpid="$(head -1 "$WS_C/hx-479/pids")"
  assert_ok "the heartbeat loop's pid is recorded in pids and it is running" alive "$hbpid"
  echo 0 >"$WS_C/hx-lock/heartbeat"; sleep 2.5
  assert_eq "$(( $(date +%s) - $(cat "$WS_C/hx-lock/heartbeat") < 5 ))" "1" "the loop keeps refreshing the heartbeat by itself"
  ws_call r_lock_state | grep -q '^held 479 lane-a '; assert_eq "$?" "0" "r_lock_state names the holder"
  ws_unlock 479; assert_no "release removes the lock" test -e "$WS_C/hx-lock"
  sleep 1.5; assert_no "the heartbeat loop ends once the lock is gone" alive "$hbpid"
  finish ) || rc=1

echo "# lock: waiting and breaking"
( fresh_env
  seed_lock 111 lane-b 999999 10
  export WS_LOCK_TIMEOUT=$(host_is_windows && [[ "$(uname -s)" == MINGW* ]] && echo 8 || echo 1) WS_OWNER_LIVE_CMD=false   # (#608: a ws_call spawns a bash, ~1 s each on Git Bash)
  out="$(ws_lock 222 lane-c $$ 2>&1)"; rc=$?
  assert_eq "$rc" "1" "a held lock with a live heartbeat: the waiter waits, then gives up at its timeout"
  [[ "$out" == *"held by #111"*"waiting"* ]]; assert_eq "$?" "0" "the waiter says it is waiting on #111"
  assert_eq "$(sed -n 's/^issue=//p' "$WS_C/hx-lock/owner")" "111" "the holder keeps the lock"
  [[ "$out" != *agent-paused* ]]; assert_eq "$?" "0" "a waiter never labels itself agent-paused"
  finish ) || rc=1
# #682: the timeout was measured in whole $SECONDS and checked BEFORE the "waiting" line, so a waiter that started
# just before a wall-clock second boundary gave up at once, after ~25ms, without ever saying who held the lock.
( fresh_env
  seed_lock 111 lane-b 999999 10
  export WS_LOCK_TIMEOUT=1 WS_OWNER_LIVE_CMD=false
  if [[ "$(date +%N)" =~ ^[0-9]{9}$ ]]; then
    miss=0
    for i in 1 2 3 4 5; do   # start ~25ms before a second boundary: the old waiter missed 10/10
      while (( 10#$(date +%N) < 975000000 )); do :; done
      out="$(ws_lock 222 lane-c $$ 2>&1)"; [[ "$out" == *"held by #111"*"waiting"* ]] || miss=$((miss+1))
    done
    assert_eq "$miss" "0" "a waiter that starts at a second boundary still says it is waiting on #111 (5/5)"
  fi
  finish ) || rc=1
( fresh_env   # deterministic: a stubbed clock that advances 300ms per reading
  seed_lock 111 lane-b 999999 10
  export WS_LOCK_TIMEOUT=2 WS_OWNER_LIVE_CMD=false WS_POLL=0.01
  echo 0 >"$T/clk"
  # a file, not a variable: ws_lock reads the clock in a $(...) subshell
  ws_clock_ms(){ local c; c="$(<"$T/clk")"; echo $((c+300)) >"$T/clk"; echo "$c"; }
  out="$(ws_lock 222 lane-c $$ 2>&1)"; rc=$?
  assert_eq "$rc" "1" "a held lock: the waiter gives up at its timeout"
  [[ "$out" == *"held by #111"*"waiting"* ]]; assert_eq "$?" "0" "...after telling the operator who holds the lock"
  assert_eq "$(( $(<"$T/clk") - 300 >= 2000 ))" "1" "...and not before WS_LOCK_TIMEOUT seconds on the clock have passed"
  finish ) || rc=1
( fresh_env
  mkdir -p "$WS_C/hx-111"; seed_lock 111 lane-b 999999 2000
  export WS_LOCK_TIMEOUT=1 WS_OWNER_LIVE_CMD=true
  ws_lock 222 lane-c $$ >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1" "heartbeat OLD but the owner lane is live: not stale, the waiter waits"
  assert_ok "the live owner's folder is untouched" test -d "$WS_C/hx-111"
  assert_eq "$(sed -n 's/^issue=//p' "$WS_C/hx-lock/owner")" "111" "and it still holds the lock"
  finish ) || rc=1
( fresh_env
  mkdir -p "$WS_C/hx-111"; seed_lock 111 lane-b 999999 100
  export WS_LOCK_TIMEOUT=1 WS_OWNER_LIVE_CMD=false
  ws_lock 222 lane-c $$ >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1" "owner lane GONE but heartbeat fresh: not stale, the waiter waits"
  assert_ok "that owner's folder is untouched" test -d "$WS_C/hx-111"
  finish ) || rc=1
( fresh_env
  # a stale run: a recorded process, a process under its folder, a task, ~/.claude.json project entries
  mkdir -p "$WS_C/hx-111/clone" "$WS_C/hx-222"; : >"$WS_C/hx-222/keep"
  sleep 300 & rec=$!; sleep 300 & under=$!; sleep 300 & other=$!
  echo "$rec" >"$WS_C/hx-111/pids"; echo "$under" >"$FAKE_PROCS.111"
  echo 'hx-111\run' >"$WS_C/hx-111/tasks"; echo 'hx-111\run' >"$FAKE_TASKS"
  python3 - "$HOME/.claude.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["projects"]["C:\\hx-111\\clone"] = {"a": 1}; json.dump(d, open(p, "w"))
PY
  seed_lock 111 lane-b 999999 2000
  export WS_OWNER_LIVE_CMD=false WS_LOCK_TIMEOUT=5
  ws_lock 333 lane-c $$ >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "heartbeat old AND owner lane gone: the breaker runs and the waiter takes the lock"
  assert_eq "$(sed -n 's/^issue=//p' "$WS_C/hx-lock/owner")" "333" "the lock is now the waiter's"
  sleep 0.3
  assert_no "breaker killed the pid listed in the stale run's pids" alive "$rec"
  assert_no "breaker killed a process whose command line is under its folder" alive "$under"
  assert_ok "breaker killed nothing else" alive "$other"
  assert_no "breaker deleted the stale run's task" grep -q 'hx-111' "$FAKE_TASKS"
  assert_no "breaker deleted the stale run's C:\\hx-111\\" test -e "$WS_C/hx-111"
  assert_ok "breaker left another run's folder alone" test -e "$WS_C/hx-222/keep"
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["projects"]; sys.exit(0 if "C:\\hx-111\\clone" not in p and "C:\\hx-smoke" in p and "C:\\Users\\pc\\work" in p else 1)' "$HOME/.claude.json"
  assert_eq "$?" "0" "breaker dropped the stale run's ~/.claude.json entries, not the others"
  kill $other 2>/dev/null; ws_cleanup 333 >/dev/null
  finish ) || rc=1
( fresh_env
  mkdir -p "$WS_C/hx-lock"   # a lock whose holder died between its mkdir and its writes
  touch -d '2 hours ago' "$WS_C/hx-lock"
  export WS_LOCK_TIMEOUT=5
  ws_lock 444 lane-d $$ >/dev/null 2>&1
  assert_eq "$?" "0" "an ownerless lock directory older than the stale limit is dropped and taken"
  ws_cleanup 444 >/dev/null
  finish ) || rc=1

# --- #1033: a FIFO queue, a hold cap and a visible lock ----------------------------------------------------------------
# wait_until <command> [tenths of a second] — poll a condition (the waiters run in the background).
wait_until(){ local i; for ((i=0; i<${2:-100}; i++)); do eval "$1" && return 0; sleep 0.1; done; return 1; }
owner_issue(){ sed -n 's/^issue=//p' "$WS_C/hx-lock/owner" 2>/dev/null; }
queued_issues(){ ws_call r_queue_state | awk '{printf "%s ", $2}' | sed 's/ $//'; }
age_taken(){ echo $(( $(date +%s) - $1 )) >"$WS_C/hx-lock/taken"; }   # pretend the lock was taken that many seconds ago

echo "# lock: FIFO queue"
( fresh_env
  ws_lock 111 lane-a $$ >/dev/null
  # B polls slowly, C fast: when A lets go C's poll lands first, and must still lose to B (it queued later)
  ( WS_POLL=1; ws_lock 222 lane-b $$ >"$T/b.out" 2>&1; echo $? >"$T/b.rc" ) &
  wait_until '[[ "$(queued_issues)" == 222 ]]' || true
  ( WS_POLL=0.1; ws_lock 333 lane-c $$ >"$T/c.out" 2>&1; echo $? >"$T/c.rc" ) &
  wait_until '[[ "$(queued_issues)" == "222 333" ]]'; assert_eq "$?" "0" "B queued first, then C: the queue is B, C"
  ws_call r_queue_join 222 lane-b $$ >/dev/null
  assert_eq "$(queued_issues)" "222 333" "one issue has at most one ticket: a second join is a refresh, not a second place"
  ws_unlock 111
  wait_until '[[ -f "$T/b.rc" ]]' 80; assert_eq "$(cat "$T/b.rc" 2>/dev/null)" "0" "A releases: B (oldest ticket) gets the lock"
  assert_eq "$(owner_issue)" "222" "...even though C polled first"
  assert_no "C does not take it while B holds it" test -f "$T/c.rc"
  assert_eq "$(queued_issues)" "333" "B's ticket is gone once it holds the lock; C is still queued"
  ws_unlock 222
  wait_until '[[ -f "$T/c.rc" ]]' 80; assert_eq "$(cat "$T/c.rc" 2>/dev/null)" "0" "B releases: C gets it next"
  assert_eq "$(owner_issue)" "333" "the lock is C's"
  assert_eq "$(queued_issues)" "" "and the queue is empty"
  ws_cleanup 333 >/dev/null; wait
  finish ) || rc=1
( fresh_env
  # no re-take while others wait: A releases and asks again at once, B (queued) wins, A goes behind B and behind C
  ws_lock 111 lane-a $$ >/dev/null
  ( WS_POLL=0.5; ws_lock 222 lane-b $$ >"$T/b.out" 2>&1; echo $? >"$T/b.rc" ) &
  wait_until '[[ "$(queued_issues)" == 222 ]]' || true
  ( WS_POLL=0.5; ws_lock 333 lane-c $$ >"$T/c.out" 2>&1; echo $? >"$T/c.rc" ) &
  wait_until '[[ "$(queued_issues)" == "222 333" ]]' || true
  ws_unlock 111
  ( WS_POLL=0.1; ws_lock 111 lane-a $$ >"$T/a.out" 2>&1; echo $? >"$T/a.rc" ) &
  wait_until '[[ -f "$T/b.rc" ]]' 80; assert_eq "$(owner_issue)" "222" "A releases and re-locks at once: B holds the lock, not A"
  assert_eq "$(queued_issues)" "333 111" "A is queued behind C (already queued) as well as B"
  assert_no "A did not get the lock back" test -f "$T/a.rc"
  ws_unlock 222; wait_until '[[ -f "$T/c.rc" ]]' 80; assert_eq "$(owner_issue)" "333" "next is C"
  ws_unlock 333; wait_until '[[ -f "$T/a.rc" ]]' 80; assert_eq "$(owner_issue)" "111" "A last"
  ws_cleanup 111 >/dev/null; wait
  finish ) || rc=1
( fresh_env
  # an unqueued newcomer finds a free lock and an empty queue: it takes it with no ticket left behind
  ws_lock 111 lane-a $$ >/dev/null; assert_eq "$(queued_issues)" "" "an uncontended lock leaves no ticket"
  ws_cleanup 111 >/dev/null
  # a waiter that gives up leaves the queue
  seed_lock 999 lane-z 999999 10; export WS_LOCK_TIMEOUT=1
  ws_lock 222 lane-b $$ >/dev/null 2>&1; assert_eq "$(queued_issues)" "" "a waiter that times out takes its ticket with it"
  out="$(ws_lock 222 lane-b $$ 2>&1)"; [[ "$out" == *"queue position 1"* ]]; assert_eq "$?" "0" "a waiter says its place in the queue"
  finish ) || rc=1

echo "# lock: dead waiters do not block the queue"
( fresh_env
  printf '#!/usr/bin/env bash\n[ "$1" != lane-dead ]\n' >"$T/bin/live"; chmod +x "$T/bin/live"
  export WS_OWNER_LIVE_CMD="$T/bin/live" WS_LOCK_TIMEOUT=3
  ws_call r_queue_join 555 lane-dead 999999 >/dev/null; touch -d '2 hours ago' "$WS_C"/hx-queue/*-555
  ws_lock 222 lane-b $$ >/dev/null 2>&1; assert_eq "$?" "0" "a ticket stale for over WS_STALE_SEC whose lane is gone is skipped: the next live ticket gets the lock"
  assert_eq "$(queued_issues)" "" "...and the dead ticket is dropped"
  ws_cleanup 222 >/dev/null
  # stale refresh but the lane is still live: it keeps its place, the newcomer waits
  ws_call r_queue_join 556 lane-slow $$ >/dev/null; touch -d '2 hours ago' "$WS_C"/hx-queue/*-556
  ws_lock 222 lane-b $$ >/dev/null 2>&1; assert_eq "$?" "1" "a stale ticket whose lane is live keeps its place"
  ws_call r_queue_drop "$(ls "$WS_C/hx-queue" | grep -- -556)" 1800 >/dev/null
  # lane gone but the ticket is fresh: not dead yet
  ws_call r_queue_join 557 lane-dead 999999 >/dev/null; ws_call r_queue_drop "$(ls "$WS_C/hx-queue" | grep -- -557)" 1800
  assert_eq "$(queued_issues)" "557" "a fresh ticket is never dropped, whatever its lane"
  finish ) || rc=1

echo "# lock: the hold cap"
( fresh_env; export WS_HB_INTERVAL=300   # the exec gate on its own: the heartbeat's enforcement (#1040) is tested below
  ws_lock 111 lane-a $$ >/dev/null; ws_isolate 111 >/dev/null
  age_taken 100; ws_call r_queue_join 222 lane-b $$ >/dev/null
  out="$(bash "$W/winsma.sh" exec 111 base 'echo under-the-cap' 2>&1)"; rc2=$?
  assert_eq "$rc2" "0" "inside WS_HOLD_MAX a queued waiter changes nothing"; [[ "$out" == *under-the-cap* ]]; assert_eq "$?" "0" "...and the command ran"
  age_taken 6000
  out="$(bash "$W/winsma.sh" exec 111 base 'echo past-the-cap' 2>&1)"; rc2=$?
  assert_ok "past WS_HOLD_MAX with a ticket queued, exec is refused (non-zero)" test "$rc2" -ne 0
  [[ "$out" == *"hold cap reached, 1 lane(s) queued: release and re-queue"* ]]; assert_eq "$?" "0" "...naming the cap and the queue"
  [[ "$out" != *past-the-cap* ]]; assert_eq "$?" "0" "...and the command did not run"
  ( WS_LOCK_TIMEOUT=0 WS_POLL=0.1; ws_lock 222 lane-b $$ >/dev/null 2>&1; echo $? >"$T/b.rc" ) &
  ws_unlock 111; wait_until '[[ -f "$T/b.rc" ]]' 80
  assert_eq "$(cat "$T/b.rc")" "0" "once A releases, B takes the lock on its next poll"; assert_eq "$(owner_issue)" "222" "the lock is B's"
  ws_cleanup 222 >/dev/null; wait
  finish ) || rc=1
( fresh_env; export WS_HB_INTERVAL=300
  ws_lock 111 lane-a $$ >/dev/null; ws_isolate 111 >/dev/null; age_taken 6000
  out="$(bash "$W/winsma.sh" exec 111 base 'echo nobody-waits' 2>&1)"; assert_eq "$?" "0" "past the cap with no one queued: A may keep exec'ing"
  ws_call r_queue_join 111 lane-a $$ >/dev/null
  assert_eq "$(bash "$W/winsma.sh" exec 111 base 'echo own-ticket-only' 2>&1 | tail -1)" "own-ticket-only" "...and A's own ticket is not another lane"
  ws_cleanup 111 >/dev/null
  finish ) || rc=1
( fresh_env; export WS_HB_INTERVAL=300
  # an exec already running is never killed because the cap passed and someone queued up behind it
  ws_lock 111 lane-a $$ >/dev/null; ws_isolate 111 >/dev/null
  ( bash "$W/winsma.sh" exec 111 base 'sleep 3; echo finished-after-cap' >"$T/x.out" 2>&1; echo $? >"$T/x.rc" ) &
  sleep 0.5; age_taken 6000; ws_call r_queue_join 222 lane-b $$ >/dev/null
  wait_until '[[ -f "$T/x.rc" ]]' 100
  assert_eq "$(cat "$T/x.rc")" "0" "a running exec finishes when the cap passes mid-command"; grep -q finished-after-cap "$T/x.out"; assert_eq "$?" "0" "...with its output"
  ws_cleanup 111 >/dev/null
  finish ) || rc=1
( fresh_env
  # a `run` is one acquisition for exactly one command: its own exec is not refused by the cap, even with B queued behind it
  export WS_HOLD_MAX=-1; ws_call r_queue_join 479 lane-a $$ >/dev/null; ws_call r_queue_join 222 lane-b $$ >/dev/null
  out="$(ws_run 479 base 'echo ran-once' 2>&1)"; assert_eq "$?" "0" "a run is never refused by the cap"
  [[ "$out" == *ran-once* ]]; assert_eq "$?" "0" "...its command ran"
  assert_no "...and the lock is released at the end" test -e "$WS_C/hx-lock"
  assert_eq "$(queued_issues)" "222" "...leaving B first in line"
  finish ) || rc=1

echo "# lock: the heartbeat enforces the hold cap (#1040)"
( fresh_env
  # a driver script: lock, isolate, sleep — no exec, so the exec gate never fires
  ws_lock 111 lane-a $$ >/dev/null; ws_isolate 111 >/dev/null; age_taken 6000
  hbpid="$(head -1 "$WS_C/hx-111/pids")"; sleep 2.5
  assert_eq "$(owner_issue)" "111" "past WS_HOLD_MAX with nobody queued, the heartbeat leaves the lock alone"
  assert_ok "...and keeps running" alive "$hbpid"
  ws_call r_queue_join 222 lane-b $$ >/dev/null
  wait_until '[[ -z "$(owner_issue)" ]]' 60
  assert_no "past WS_HOLD_MAX with a lane queued, the heartbeat releases the lock (no exec ever ran)" test -e "$WS_C/hx-lock"
  wait_until '! alive "$hbpid"' 30; assert_no "...and the heartbeat loop ends" alive "$hbpid"
  ( WS_LOCK_TIMEOUT=0 WS_POLL=0.1; ws_lock 222 lane-b $$ >/dev/null 2>&1; echo $? >"$T/b.rc" ) &
  wait_until '[[ -f "$T/b.rc" ]]' 80; assert_eq "$(owner_issue)" "222" "...so the queued waiter takes it"
  ws_cleanup 222 >/dev/null; ws_cleanup 111 >/dev/null; wait
  finish ) || rc=1
( fresh_env
  # inside the cap a queued lane changes nothing; a ticket of the holder's own issue is not another lane; a stale ticket is not a lane
  ws_lock 111 lane-a $$ >/dev/null; age_taken 100; ws_call r_queue_join 222 lane-b $$ >/dev/null; sleep 2.5
  assert_eq "$(owner_issue)" "111" "inside WS_HOLD_MAX the heartbeat keeps the lock with a lane queued"
  ws_call r_queue_leave 222 >/dev/null; age_taken 6000; ws_call r_queue_join 111 lane-a $$ >/dev/null; sleep 2.5
  assert_eq "$(owner_issue)" "111" "past the cap, the holder's own ticket is not another lane"
  ws_cleanup 111 >/dev/null
  finish ) || rc=1
( fresh_env
  # a `run` is one command: the cap does not cut it short, the hard ceiling does
  export WS_HOLD_MAX=1 WS_HOLD_HARD=0
  WS_LOCK_RUN=1 ws_lock 111 lane-a $$ >/dev/null; ws_call r_queue_join 222 lane-b $$ >/dev/null; sleep 3.5
  assert_eq "$(owner_issue)" "111" "a lock taken by run is not released at WS_HOLD_MAX, even with a lane queued"
  ws_cleanup 111 >/dev/null; ws_call r_queue_leave 222 >/dev/null
  export WS_HOLD_HARD=2
  WS_LOCK_RUN=1 ws_lock 111 lane-a $$ >/dev/null; ws_call r_queue_join 222 lane-b $$ >/dev/null; sleep 5
  assert_no "...but is past WS_HOLD_HARD" test -e "$WS_C/hx-lock"
  ws_cleanup 111 >/dev/null
  finish ) || rc=1

echo "# lock: an idle lane does not hold the lock (#1040)"
( fresh_env
  export WS_OWNER_LIVE_CMD=true WS_IDLE_MAX=1 WS_LOCK_TIMEOUT=2 WS_POLL=0.3
  ws_lock 111 lane-a $$ >/dev/null; ws_isolate 111 >/dev/null
  WS_OWNER_ACTIVE_CMD=true ws_lock 222 lane-b $$ >/dev/null 2>&1; assert_eq "$?" "1" "a holder whose session is working keeps the lock"
  assert_eq "$(owner_issue)" "111" "...it is still A's"; assert_no "...and no idle note is left" test -e "$WS_C/hx-lock/idle_since"
  export WS_LOCK_TIMEOUT=10
  out="$(WS_OWNER_ACTIVE_CMD=false ws_lock 222 lane-b $$ 2>&1)"; assert_eq "$?" "0" "a holder whose turn ended, past WS_IDLE_MAX, loses the lock to the first in line"
  [[ "$out" == *"WS_IDLE_MAX"* ]]; assert_eq "$?" "0" "...and the waiter says why"
  assert_eq "$(owner_issue)" "222" "the lock is B's"; assert_no "the idle holder's run folder is cleaned" test -e "$WS_C/hx-111"
  ws_cleanup 222 >/dev/null
  finish ) || rc=1
( fresh_env
  # a lane that comes back to work resets the clock; the primitives refuse a stranger
  export WS_OWNER_LIVE_CMD=true
  ws_lock 111 lane-a $$ >/dev/null
  ws_call r_lock_idle 111 idle >/dev/null; assert_ok "idle is noted" test -s "$WS_C/hx-lock/idle_since"
  ws_call r_lock_idle 111 active >/dev/null; assert_no "active clears the note" test -e "$WS_C/hx-lock/idle_since"
  assert_no "an idle note for another issue is refused" ws_call r_lock_idle 222 idle
  assert_no "no break without an idle note" ws_call r_lock_break_idle 111 0; assert_eq "$(owner_issue)" "111" "...the lock stays"
  ws_call r_lock_idle 111 idle >/dev/null
  assert_no "no break before the idle time has passed" ws_call r_lock_break_idle 111 100; assert_eq "$(owner_issue)" "111" "...the lock stays"
  ws_cleanup 111 >/dev/null
  finish ) || rc=1

echo "# lock: WS_POLL below the rule is clamped (#1040)"
( fresh_env; unset WS_POLL_MIN
  assert_eq "$(ws_poll_clamp 15 2>/dev/null)" "300" "WS_POLL=15 from a lane env is clamped to 300"
  assert_eq "$(ws_poll_clamp 299 2>/dev/null)" "300" "...so is 299"
  assert_eq "$(ws_poll_clamp 300)" "300" "300 stays"; assert_eq "$(ws_poll_clamp 600)" "600" "a slower poll stays"
  assert_eq "$(ws_poll_clamp 0.2 2>/dev/null)" "300" "a fractional poll is clamped too"
  out="$(ws_poll_clamp 15 2>&1 >/dev/null)"; [[ "$out" == *"WS_POLL=15"*"300"* ]]; assert_eq "$?" "0" "...and the lane is told"
  assert_eq "$(WS_POLL_MIN=0 ws_poll_clamp 0.2)" "0.2" "the test seam WS_POLL_MIN lowers the floor"
  # end to end: a waiter with WS_POLL=15 sleeps 300 between polls
  ws_call r_lock_take 111 lane-a $$ >/dev/null
  ( sleep(){ echo "$1" >"$T/slept"; exit 9; }; export WS_POLL=15 WS_OWNER_LIVE_CMD=true WS_OWNER_ACTIVE_CMD=true; ws_lock 222 lane-b $$ >"$T/w.out" 2>&1 )
  assert_eq "$(cat "$T/slept" 2>/dev/null)" "300" "ws_lock with WS_POLL=15 polls every 300 s"
  [[ "$(cat "$T/w.out")" == *"waiting 300s"* ]]; assert_eq "$?" "0" "...and says so"
  rm -rf "$WS_C/hx-lock" "$WS_C/hx-queue"
  finish ) || rc=1

echo "# lock: the hard ceiling"
( fresh_env; export WS_HB_INTERVAL=300   # the waiter's ceiling on its own: the heartbeat's cap enforcement (#1040) is tested above
  # a runaway holder: past WS_HOLD_HARD a queued waiter may break a LIVE holder (its run is cleaned first)
  export WS_HOLD_HARD=100 WS_LOCK_TIMEOUT=5
  ws_lock 111 lane-a $$ >/dev/null; ws_isolate 111 >/dev/null; : >"$WS_C/hx-111/mark"
  age_taken 50
  ws_lock 222 lane-b $$ >/dev/null 2>&1; assert_eq "$?" "1" "under the hard ceiling a live holder is never broken"
  assert_eq "$(owner_issue)" "111" "...it keeps the lock"
  age_taken 500
  out="$(ws_lock 222 lane-b $$ 2>&1)"; assert_eq "$?" "0" "past the hard ceiling the queued waiter breaks the holder and takes the lock"
  [[ "$out" == *"WS_HOLD_HARD"* ]]; assert_eq "$?" "0" "...and says why"
  assert_eq "$(owner_issue)" "222" "the lock is B's"; assert_no "the runaway holder's run folder is cleaned" test -e "$WS_C/hx-111"
  ws_cleanup 222 >/dev/null
  # WS_HOLD_HARD=0 switches the ceiling off
  export WS_HOLD_HARD=0 WS_LOCK_TIMEOUT=1
  ws_lock 111 lane-a $$ >/dev/null; age_taken 99999
  ws_lock 222 lane-b $$ >/dev/null 2>&1; assert_eq "$?" "1" "WS_HOLD_HARD=0: no ceiling"
  ws_cleanup 111 >/dev/null
  finish ) || rc=1

echo "# status: the lock, the holder and the queue"
( fresh_env
  seed_lock 111 hz-main-i111 $$ 42; age_taken 4500
  ws_call r_queue_join 222 hz-main-i222 $$ >/dev/null; sleep 1.1; ws_call r_queue_join 333 hz-main-i333 $$ >/dev/null
  out="$(bash "$W/winsma.sh" status 2>&1)"; assert_eq "$?" "0" "winsma.sh status succeeds on a reachable host"
  [[ "$out" == *"#111"*"hz-main-i111"*"1h15m"*"heartbeat 4"[0-9]"s"* ]]; assert_eq "$?" "0" "names the holder, how long it has held, the heartbeat age"
  [[ "$out" == *"#222"*"#333"* && "$out" != *"#333"*"#222"* ]]; assert_eq "$?" "0" "lists the queue in order"
  [[ "$(grep -c 'waiting' <<<"$out")" == 2 ]]; assert_eq "$?" "0" "...each ticket with its wait"
  seed_free(){ rm -rf "$WS_C/hx-lock" "$WS_C/hx-queue"; }; seed_free
  out="$(bash "$W/winsma.sh" status 2>&1)"; [[ "$out" == *"free"* ]]; assert_eq "$?" "0" "a free lock says free"
  printf '#!/usr/bin/env bash\nexit 255\n' >"$T/bin/downssh"; printf '#!/usr/bin/env bash\nsleep 30\n' >"$T/bin/hangssh"; chmod +x "$T/bin/"*ssh
  out="$(WINSMA_SSH="$T/bin/downssh" bash "$W/winsma.sh" status 2>&1)"; rc2=$?
  assert_ok "an unreachable host: status exits non-zero" test "$rc2" -ne 0; assert_eq "$out" "winsma: unreachable" "...with the one line"
  finish ) || rc=1
( fresh_env
  # harness status: the winsma block, the unreachable line, and nothing at all when there is no Windows host
  export STATE_DIR="$T/state" HARNESS_SESS_PREFIX=wstest HARNESS_POOL=1; mkdir -p "$STATE_DIR"
  seed_lock 111 hz-main-i111 $$ 42; age_taken 4500; ws_call r_queue_join 222 hz-main-i222 $$ >/dev/null
  S="$HERE/../scripts/status.sh"
  out="$(bash "$S" 2>&1)"
  [[ "$out" == *"#111"*"hz-main-i111"*"#222"* ]]; assert_eq "$?" "0" "harness status names the holder and the queued lane"
  [[ "$out" == *"worker"* ]]; assert_eq "$?" "0" "...inside the normal status"
  printf '#!/usr/bin/env bash\nexit 255\n' >"$T/bin/downssh"; printf '#!/usr/bin/env bash\nsleep 30\n' >"$T/bin/hangssh"; chmod +x "$T/bin/"*ssh
  out="$(WINSMA_SSH="$T/bin/downssh" bash "$S" 2>&1)"
  [[ "$(grep -c 'winsma: unreachable' <<<"$out")" == 1 ]]; assert_eq "$?" "0" "an ssh that fails: one 'winsma: unreachable' line"
  [[ "$out" == *"worker"* ]]; assert_eq "$?" "0" "...and the rest of status still renders"
  t0=$SECONDS; out="$(WINSMA_SSH="$T/bin/hangssh" WS_STATUS_TIMEOUT=2 bash "$S" 2>&1)"; t1=$((SECONDS - t0))
  [[ "$(grep -c 'winsma: unreachable' <<<"$out")" == 1 && "$out" == *"worker"* ]]; assert_eq "$?" "0" "an ssh that hangs: 'winsma: unreachable' too, status still renders"
  assert_ok "...within the timeout, not 30s" test "$t1" -lt 15
  out="$(unset HARNESS_WINDOWS_HOST; bash "$S" 2>&1)"
  assert_no "HARNESS_WINDOWS_HOST unset: no winsma line" grep -qi winsma <<<"$out"
  finish ) || rc=1

echo "# docs: the queue and the cap"
( D="$HERE/../docs/windows-smoke.md"
  for k in WS_HOLD_MAX WS_HOLD_HARD hx-queue; do grep -q "$k" "$D"; assert_eq "$?" "0" "docs/windows-smoke.md documents $k"; done
  grep -qi 'hold cap\|WS_HOLD_MAX' "$HERE/../prompts/_windows_suite.md" && grep -qi 'hold cap\|WS_HOLD_MAX' "$HERE/../prompts/_windows_rtdd.md"; assert_eq "$?" "0" "both Windows prompts name the cap"
  assert_no "the docs no longer teach iterating in one lock session" grep -qi 'iterate in one lock session' "$D"
  finish ) || rc=1

echo "# park: a waiting lane gives up its pool slot and keeps its place (#1034)"
# fake_gh — a gh that keeps each issue's labels in $T/labels.<n> and every comment in $T/comments.<n>.
fake_gh(){ GHLOG="$T/gh.log"; : >"$GHLOG"
  gh(){ local sub="$1 $2" n="$3" a; echo "gh $*" >>"$GHLOG"; shift 3
    case "$sub" in
      "issue comment") while [[ $# -gt 0 ]]; do [[ "$1" == --body ]] && printf '%s\n' "$2" >>"$T/comments.$n"; shift; done;;
      "issue edit") touch "$T/labels.$n"; while [[ $# -gt 0 ]]; do
          case "$1" in
            --add-label) grep -qxF "$2" "$T/labels.$n" || echo "$2" >>"$T/labels.$n";;
            --remove-label) grep -vxF "$2" "$T/labels.$n" >"$T/labels.$n.x"; mv "$T/labels.$n.x" "$T/labels.$n";;
          esac; shift; done;;
    esac; return 0; }
  labels_of(){ sort "$T/labels.$1" 2>/dev/null | tr '\n' ' '; }; }
( fresh_env; fake_gh; export WS_PARK_CHECK_PUSHED=0 WS_OWNER_LIVE_CMD=true
  ws_lock 111 lane-a $$ >/dev/null                      # lane A holds the lock, its heartbeat is live
  echo "agent-working" >"$T/labels.222"; echo "agent-working" >"$T/labels.333"
  ws_call r_queue_join 222 lane-b $$ >/dev/null; sleep 0.05; ws_call r_queue_join 333 lane-c $$ >/dev/null   # B queues first, C after
  out="$(ws_park 222 acme/widget 2>&1)"; rc=$?
  assert_eq "$rc" "0" "lane B, queued behind A and not next, parks"
  assert_eq "$(labels_of 222)" "waiting-winsma " "B's issue carries the waiting label and no agent-working"
  assert_eq "$(grep -c 'issue edit' "$GHLOG")" "1" "the label swap is ONE edit: the issue is never seen with neither label"
  grep -q -- '--add-label waiting-winsma --remove-label agent-working' "$GHLOG"; assert_eq "$?" "0" "...adding the waiting label and removing agent-working"
  [[ "$out" != *agent-paused* ]] && ! grep -q 'agent-paused' "$GHLOG"; assert_eq "$?" "0" "parking never touches agent-paused (#417's nudge keys on it)"
  head -1 "$T/comments.222" | grep -qxF '<!-- harness-handoff issue=222 branch=issue/222 -->' || head -1 "$T/comments.222" | grep -q '^<!-- harness-handoff issue=222 branch='
  assert_eq "$?" "0" "a handoff comment is posted (the marker the resume path reads)"
  assert_eq "$(ws_call r_queue_state | awk '{print $2}' | tr '\n' ' ')" "222 333 " "B's ticket survives the park, still ahead of C"
  ws_turn 222 >/dev/null; assert_eq "$?" "1" "while A holds the lock B is not next"
  ws_turn 333 >/dev/null; assert_eq "$?" "1" "C is behind B"
  # the engine's refresh keeps the place while no lane is alive: an old ticket is touched, not dropped
  tk="$(ls "$WS_C"/hx-queue/*-222)"; touch -d '2 hours ago' "$tk"
  ws_turn 222 >/dev/null; age=$(( $(date +%s) - $(stat -c %Y "$tk") )); assert_eq "$(( age < 60 ))" "1" "turn refreshes the parked ticket"
  ws_unlock 111
  out="$(ws_turn 222)"; assert_eq "$?" "0" "A released: B's ticket is next and the lock is free"; [[ "$out" == ready* ]]; assert_eq "$?" "0" "...and turn says ready"
  ws_turn 333 >/dev/null; assert_eq "$?" "1" "C is still not next"
  ws_lock 222 lane-b2 $$ >/dev/null 2>&1; assert_eq "$?" "0" "B's resumed lane takes the lock on its first attempt"
  assert_eq "$(sed -n 's/^issue=//p' "$WS_C/hx-lock/owner")" "222" "...ahead of C, which queued after B"
  assert_eq "$(ws_call r_queue_state | awk '{print $2}' | tr '\n' ' ')" "333 " "C is still queued, B's ticket is gone"
  finish ) || rc=1
( fresh_env; fake_gh; export WS_PARK_CHECK_PUSHED=0 WS_OWNER_LIVE_CMD=true
  ws_lock 111 lane-a $$ >/dev/null
  ws_park 222 acme/widget >/dev/null 2>&1; assert_eq "$?" "0" "a lane that never queued takes a ticket when it parks"
  assert_eq "$(ws_call r_queue_state | awk '{print $2}' | tr '\n' ' ')" "222 " "...at the back"
  ws_call r_queue_leave 222 >/dev/null; ws_turn 222 >/dev/null; assert_eq "$?" "1" "a lost ticket is re-taken by turn (not stuck for ever)"
  assert_eq "$(ws_call r_queue_state | awk '{print $2}' | tr '\n' ' ')" "222 " "...so the issue is still in the queue"
  finish ) || rc=1
( fresh_env; fake_gh; export WS_PARK_CHECK_PUSHED=0   # next in line with the lock free: park refuses, the lane should take the lock
  ws_call r_queue_join 222 lane-b $$ >/dev/null
  ws_park 222 acme/widget >/dev/null 2>&1; assert_eq "$?" "4" "next with the lock free: park refuses (take the lock)"
  assert_eq "$(labels_of 222)" "" "...and changed no label"
  assert_eq "$(grep -c 'gh ' "$GHLOG")" "0" "...and made no gh call"
  finish ) || rc=1
( fresh_env; fake_gh; export WS_PARK_CHECK_PUSHED=0 WS_OWNER_LIVE_CMD=false
  seed_lock 111 lane-a 999999 2000                      # a holder whose heartbeat is old AND whose lane is gone
  ws_call r_queue_join 222 parked-222 - >/dev/null
  ws_turn 222 >/dev/null; assert_eq "$?" "0" "a dead holder: the first parked ticket is woken, the resumed lane breaks the lock"
  export WS_OWNER_LIVE_CMD=true; ws_turn 222 >/dev/null; assert_eq "$?" "1" "an old heartbeat whose lane is live is not broken, not woken"
  finish ) || rc=1
( fresh_env; fake_gh; export WS_PARK_CHECK_PUSHED=0 WS_OWNER_LIVE_CMD=true
  ws_lock 111 lane-a $$ >/dev/null
  ws_call r_queue_join 222 lane-b $$ >/dev/null
  export WINSMA_SSH=false                               # the host cannot be reached
  out="$(ws_turn 222 2>&1)"; assert_eq "$?" "2" "host unreachable: turn says so (exit 2), the engine leaves the issue parked"
  echo "agent-working" >"$T/labels.222"; : >"$GHLOG"
  ws_park 222 acme/widget >/dev/null 2>&1; assert_eq "$?" "1" "host unreachable: park refuses"
  assert_eq "$(labels_of 222)" "agent-working " "...and leaves the lane working"
  assert_eq "$(grep -c 'gh ' "$GHLOG")" "0" "...with no comment and no label edit"
  assert_no "turn without a host configured fails" env -u HARNESS_WINDOWS_HOST bash "$W/winsma.sh" turn 5
  assert_no "a non-numeric issue (hx-lock) cannot be parked" bash "$W/winsma.sh" park hx-lock acme/widget
  finish ) || rc=1
( fresh_env; fake_gh                                    # the lane's work must be pushed before the session is ended
  export WS_OWNER_LIVE_CMD=true; ws_lock 111 lane-a $$ >/dev/null; ws_call r_queue_join 222 lane-b $$ >/dev/null
  git init -q --bare "$T/origin.git"; git init -q "$T/wt"; cd "$T/wt" || exit 1
  git config user.email a@b.c; git config user.name t; git remote add origin "$T/origin.git"
  git checkout -q -b issue/222; echo a >a; git add a; git commit -q -m one
  ws_park 222 acme/widget >/dev/null 2>&1; assert_eq "$?" "1" "an unpushed branch: park refuses"
  git push -q origin issue/222; echo b >b
  ws_park 222 acme/widget >/dev/null 2>&1; assert_eq "$?" "1" "an uncommitted file: park refuses"
  git add b; git commit -q -m two
  ws_park 222 acme/widget >/dev/null 2>&1; assert_eq "$?" "1" "a commit not pushed: park refuses"
  assert_eq "$(labels_of 222)" "" "...and no label changed while it refused"
  git push -q origin issue/222
  ws_park 222 acme/widget >/dev/null 2>&1; assert_eq "$?" "0" "clean and pushed: park goes ahead"
  assert_eq "$(labels_of 222)" "waiting-winsma " "...and swaps the labels"
  cd "$HERE" || true
  finish ) || rc=1
( fresh_env; fake_gh; export WS_OWNER_LIVE_CMD=true     # the PRD review lane (#1038): --review, no branch to push
  ws_lock 111 lane-a $$ >/dev/null; echo "prd" >"$T/labels.900"; ws_call r_queue_join 900 review-900 $$ >/dev/null
  git init -q "$T/rwt"; cd "$T/rwt" || exit 1            # a worktree with no origin and no pushed branch
  ws_park 900 acme/widget >/dev/null 2>&1; assert_eq "$?" "1" "without --review an unpushed worktree is refused"
  ws_park 900 acme/widget --review >/dev/null 2>&1; assert_eq "$?" "0" "--review parks the PRD's review lane with nothing pushed"
  assert_eq "$(labels_of 900)" "prd waiting-winsma " "...the PRD gains the waiting label and keeps its prd label"
  head -1 "$T/comments.900" | grep -qxF '<!-- harness-winsma-review-park prd=900 -->'; assert_eq "$?" "0" "...with the review park marker comment"
  ! grep -q 'agent-paused\|remove-label' "$GHLOG"; assert_eq "$?" "0" "...no agent-paused, no label removed"
  ws_turn 900 >/dev/null; assert_eq "$?" "1" "while A holds the lock the PRD is not next"
  ws_unlock 111; ws_turn 900 >/dev/null; assert_eq "$?" "0" "A released: the PRD's ticket is next"
  ws_park 900 --review acme/widget >/dev/null 2>&1; assert_eq "$?" "4" "--review may come before the repo; next with the lock free: refused (take the lock)"
  cd "$HERE" || true
  finish ) || rc=1
( fresh_env
  P="$HERE/../prompts/_windows_rtdd.md"
  grep -q 'winsma.sh park {{ISSUE}} {{SLUG}}' "$P" && grep -q 'waiting-winsma' "$P" && grep -q 'NOT a checkpoint' "$P"; assert_eq "$?" "0" "the Windows rtdd prompt tells a queued lane how to park"
  for k in waiting-winsma HARNESS_LABEL_WAITING_WINSMA "winsma.sh park"; do grep -q -- "$k" "$HERE/../docs/windows-smoke.md"; assert_eq "$?" "0" "docs/windows-smoke.md documents $k"; done
  grep -q 'HARNESS_LABEL_WAITING_WINSMA' "$HERE/../docs/reference.md"; assert_eq "$?" "0" "docs/reference.md documents the label key"
  finish ) || rc=1

echo "# isolation"
( fresh_env
  ws_isolate 479; hx="$WS_C/hx-479"
  assert_ok "isolate makes pids, tasks and the work dirs" bash -c "test -f $hx/pids && test -f $hx/tasks && test -d $hx/clone && test -d $hx/tmp"
  b="$(ws_env 479 base)"; nhx="$(native_path "$hx")"   # ws_env hands native tools C:/… (cygpath -m) on a real Windows host (#608)
  for v in HARNESS_HOME HARNESS_BIN_DIR HARNESS_USER_SKILLS TMPDIR npm_config_cache HX_CLONE GIT_CONFIG_GLOBAL; do
    [[ "$b" == *"export $v=$nhx/"* ]]; assert_eq "$?" "0" "base exports $v under C:\\hx-479\\"
  done
  [[ "$b" != *CLAUDE_CONFIG_DIR* && "$b" != *"export HOME="* && "$b" != *USERPROFILE* ]]; assert_eq "$?" "0" "base sets no CLAUDE_CONFIG_DIR, HOME or USERPROFILE"
  i="$(ws_env 479 install)"; [[ "$i" == *"export CLAUDE_CONFIG_DIR=$nhx/claude-config"* && "$i" == *HARNESS_HOME* ]]; assert_eq "$?" "0" "install adds CLAUDE_CONFIG_DIR"
  [[ "$i" != *"export HOME="* ]]; assert_eq "$?" "0" "install leaves HOME alone"
  s="$(ws_env 479 suite)"; [[ "$s" == *"export HOME=$nhx/home"* && "$s" == *"export USERPROFILE="*hx-479*home* && "$s" == *HARNESS_HOME* ]]; assert_eq "$?" "0" "suite adds HOME and USERPROFILE (= the folder's home)"
  [[ "$s" != *CLAUDE_CONFIG_DIR* ]]; assert_eq "$?" "0" "suite is base + HOME/USERPROFILE only"
  assert_no "a bad mode is refused" ws_env 479 everything
  assert_no "a non-numeric issue (C:\\hx-smoke) cannot be named" ws_isolate smoke
  ws_isolate 479 --venv; assert_eq "$?" "0" "isolate --venv succeeds"; assert_ok "a python venv is made under the folder" test -e "$hx/venv/pyvenv.cfg"
  [[ "$(ws_env 479 base)" == *"export VIRTUAL_ENV=$nhx/venv"* ]]; assert_eq "$?" "0" "the venv is on the env"
  out="$(ws_exec 479 install 'printf "%s|%s|%s|%s" "$HARNESS_HOME" "$CLAUDE_CONFIG_DIR" "$PWD" "${GIT_CONFIG_COUNT:-}"' 2>&1)"
  assert_eq "$out" "$nhx/harness-home|$nhx/claude-config|$hx|1" "exec runs inside the isolation, cwd = the folder, git auth from GIT_CONFIG_COUNT"
  out="$(ws_exec 479 base 'printf "%s" "${GIT_AUTHOR_NAME}/${GIT_COMMITTER_EMAIL}"' 2>&1)"; [[ -n "$out" && "$out" == */* ]]; assert_eq "$?" "0" "identity comes from GIT_AUTHOR_* / GIT_COMMITTER_*"
  out="$(ws_exec 479 base 'printf "%s" "$GH_TOKEN"' 2>&1)"; assert_eq "$out" "$TOK" "GH_TOKEN arrives in the command's environment (sent on stdin)"
  ws_exec 479 base 'exit 7' >/dev/null 2>&1; assert_eq "$?" "7" "exec returns the command's exit status"
  ws_task_add 479 job 'cmd /c echo hi'; grep -q 'ONLOGON' "$FAKE_TASKS.log"; assert_eq "$?" "0" "a per-run task is registered logon-only"
  ! grep -qiE 'ONSTART|BOOT' "$FAKE_TASKS.log"; assert_eq "$?" "0" "never with a boot trigger"
  assert_eq "$(cat "$hx/tasks")" 'hx-479\job' "and recorded in tasks"
  ws_pid_add 479 4242; assert_eq "$(tail -1 "$hx/pids")" "4242" "pids recorded"
  assert_eq "$(grep -c . "$HOME/.gitconfig")" "1" "nothing wrote the real .gitconfig"
  finish ) || rc=1

echo "# guard"
snapshot(){ ws_isolate 479 >/dev/null; ws_guard 479 before >/dev/null; }
( fresh_env; snapshot
  out="$(ws_guard 479 after 2>&1)"; assert_eq "$?" "0" "nothing changed: the guard passes"
  finish ) || rc=1
( fresh_env; snapshot
  echo 'name = x' >>"$HOME/.gitconfig"
  out="$(ws_guard 479 after 2>&1)"; rc=$?
  assert_eq "$rc" "1" "a changed ~/.gitconfig fails the run"; [[ "$out" == *"GUARD FAILED: files"* && "$out" == *.gitconfig* ]]; assert_eq "$?" "0" "and names the file"
  finish ) || rc=1
for target in .claude/settings.json .claude/plugins/installed_plugins.json .claude/plugins/known_marketplaces.json .local/bin/harness .harness/version ghcfg/hosts.yml; do
  ( fresh_env; snapshot; echo changed >>"$HOME/$target"
    ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "1" "a changed $target fails the run"
    finish ) >/dev/null || { echo "  FAIL: a changed $target fails the run"; exit 1; }
done
( fresh_env; snapshot; echo new >"$HOME/.local/bin/harness.cmd"
  ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "1" "a NEW file in .local/bin fails the run"
  rm "$HOME/.local/bin/harness.cmd"; echo x >"$HOME/.claude/skills/new-skill"
  ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "1" "a new file in ~/.claude/skills fails the run"
  finish ) || rc=1
( fresh_env; snapshot
  echo plugin >"$HOME/.claude/plugins/.last_inuse_sweep"; mkdir -p "$HOME/.claude/plugins/cache"; echo c >"$HOME/.claude/plugins/cache/x"
  ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "0" "plugins/cache and .last_inuse_sweep churn is not the guard's business"
  finish ) || rc=1
( fresh_env; snapshot
  echo 'Harness\newtask' >>"$FAKE_TASKS"
  out="$(ws_guard 479 after 2>&1)"; assert_eq "$?" "1" "a new Harness\\* task fails the run"; [[ "$out" == *"GUARD FAILED: tasks"* && "$out" == *newtask* ]]; assert_eq "$?" "0" "and names it"
  finish ) || rc=1
( fresh_env; echo 'Harness\old' >>"$FAKE_TASKS"; snapshot
  echo 'Other\thing' >>"$FAKE_TASKS"
  ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "0" "a pre-existing Harness\\* task and a non-Harness task are not changes"
  ws_task_add 479 job 'x'; ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "0" "a task the run recorded (and cleans up) is not a change"
  : >"$FAKE_TASKS"; ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "1" "a Harness\\* task that vanished is a change"
  finish ) || rc=1
cj_edit(){ python3 - "$HOME/.claude.json" "$1" <<'PY'
import json, sys
p, code = sys.argv[1], sys.argv[2]; d = json.load(open(p)); exec(code); json.dump(d, open(p, "w"))
PY
}
( fresh_env; snapshot
  cj_edit 'd["numStartups"] += 1; d["projects"]["C:\\hx-479\\clone"] = {"lastCost": 2}; d["projects"]["c:/hx-479"] = {"s": 1}'
  out="$(ws_guard 479 after 2>&1)"; assert_eq "$?" "0" "~/.claude.json: top-level counters and projects inside C:\\hx-479 may change"
  cj_edit 'd["projects"]["C:\\Users\\pc\\work"]["lastCost"] = 9'
  out="$(ws_guard 479 after 2>&1)"; rc=$?; assert_eq "$rc" "1" "~/.claude.json: a change to a project OUTSIDE C:\\hx-479 is flagged"
  [[ "$out" == *"GUARD FAILED: claude.json"* && "$out" == *"Users"* ]]; assert_eq "$?" "0" "and names the project"
  finish ) || rc=1
( fresh_env; snapshot
  cj_edit 'd["projects"]["C:\\hx-4790\\other"] = {"a": 1}'
  ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "1" "C:\\hx-4790 is not inside C:\\hx-479"
  finish ) || rc=1
( fresh_env; export WS_CLAUDE_TOP_KEYS="bypassPermissionsModeAccepted"; snapshot
  cj_edit 'd["bypassPermissionsModeAccepted"] = True'
  ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "1" "a top-level key Harness writes (WS_CLAUDE_TOP_KEYS) is watched"
  finish ) || rc=1
( fresh_env; snapshot; rm "$HOME/.claude.json"
  ws_guard 479 after >/dev/null 2>&1; assert_eq "$?" "1" "~/.claude.json deleted: its outside projects are gone, flagged"
  finish ) || rc=1

echo "# credentials"
( fresh_env; ws_isolate 479 >/dev/null; ws_scan 479 before >/dev/null
  out="$(ws_scan 479 after 2>&1)"; assert_eq "$?" "0" "a run that wrote no token: the scan passes"
  for where in "$WS_C/hx-479/notes.txt" "$TEMP/leak" "$HOME/.claude/projects/p/s.jsonl" "$HOME/.harness/log" "$HOME/.bash_history" "$HOME/.gitconfig" "$HOME/ghcfg/hosts.yml"; do
    mkdir -p "$(dirname "$where")"; printf 'x\n%s\n' "$TOK" >"$where"
    out="$(ws_scan 479 after 2>&1)"; rc=$?
    assert_eq "$rc" "1" "the token written to ${where#$T/} is found"; [[ "$out" == *"$where"* && "$out" != *"$TOK"* ]]; assert_eq "$?" "0" "the file is named, the token never printed"
    rm -f "$where"
  done
  printf 'x-access-token:%s' "$TOK" | base64 -w0 >"$TEMP/hdr"; ws_scan 479 after >/dev/null 2>&1; assert_eq "$?" "1" "the base64 auth header form is found too"
  finish ) || rc=1
( fresh_env; echo "oauth_token: $TOK" >"$HOME/ghcfg/hosts.yml"; ws_isolate 479 >/dev/null; ws_scan 479 before >/dev/null
  ws_scan 479 after >/dev/null 2>&1; assert_eq "$?" "0" "a file that held the token BEFORE the run (the real gh login) is not the run's leak"
  finish ) || rc=1
( fresh_env; ws_isolate 479 >/dev/null; ws_scan 479 before >/dev/null
  ws_exec 479 base 'printf %s "$GH_TOKEN" >"$TMPDIR/oops"' >/dev/null 2>&1
  assert_eq "$(ws_scan 479 after >/dev/null 2>&1; echo $?)" "1" "a command that writes GH_TOKEN to disk is caught by the end-of-run scan"
  finish ) || rc=1
( fresh_env; unset GH_TOKEN; PATH="$T/bin:/usr/bin:/bin"
  assert_eq "$(ws_exec 479 base 'printf "[%s]" "${GH_TOKEN:-}"' 2>&1)" "[]" "no token available: the command runs without one"
  finish ) || rc=1

echo "# cleanup"
( fresh_env
  ws_isolate 479 >/dev/null; mkdir -p "$WS_C/hx-smoke"; echo keep >"$WS_C/hx-smoke/f"
  sleep 300 & rec=$!; sleep 300 & under=$!; sleep 300 & other=$!
  ws_pid_add 479 "$rec"; echo "$under" >"$FAKE_PROCS.479"; ws_task_add 479 job x; echo 'Harness\real' >>"$FAKE_TASKS"
  cj_edit 'd["projects"]["C:\\hx-479\\clone"] = {"a": 1}'
  ws_lock 479 lane-a $$ >/dev/null; hb="$(sed -n 1p "$WS_C/hx-479/pids")"
  ws_cleanup 479 >/dev/null 2>&1; rc=$?; sleep 0.3
  assert_eq "$rc" "0" "cleanup succeeds and winsma is clean"
  assert_no "recorded pid killed" alive "$rec"; assert_no "heartbeat loop killed" alive "$hb"; assert_no "process under the folder killed" alive "$under"
  assert_ok "a process the run did not start is left alone" alive "$other"
  assert_eq "$(cat "$FAKE_TASKS")" 'Harness\real' "recorded task deleted, other tasks left alone"
  assert_no "folder deleted" test -e "$WS_C/hx-479"; assert_no "lock released" test -e "$WS_C/hx-lock"
  assert_eq "$(cat "$WS_C/hx-smoke/f")" "keep" "C:\\hx-smoke\\ never touched"
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["projects"]; sys.exit(0 if list(p)==["C:\\Users\\pc\\work","C:\\hx-smoke"] else 1)' "$HOME/.claude.json"
  assert_eq "$?" "0" "the run's ~/.claude.json project entries are deleted, the others kept"
  kill $other 2>/dev/null
  finish ) || rc=1
( fresh_env
  ws_isolate 479 >/dev/null; ws_lock 479 lane-a $$ >/dev/null; seed_other=1
  assert_no "cleanup refuses a non-numeric folder name (hx-smoke, hx-lock)" ws_call r_cleanup smoke
  assert_ok "the lock survived that" test -d "$WS_C/hx-lock"
  mkdir -p "$WS_C/hx-lock2"; ws_call r_lock_release 888 2>/dev/null; assert_ok "release by a non-owner leaves the lock" test -d "$WS_C/hx-lock"
  ws_cleanup 479 >/dev/null
  finish ) || rc=1
( fresh_env
  ws_isolate 479 >/dev/null; echo 'hx-479\left' >>"$FAKE_TASKS"
  out="$(ws_call r_clean_check 479)"; rc=$?; assert_eq "$rc" "1" "clean check flags a run task left behind"; [[ "$out" == *"hx-479"* ]]; assert_eq "$?" "0" "and says so"
  finish ) || rc=1

( fresh_env
  ws_isolate 479 >/dev/null; sleep 300 & other=$!; ws_pid_add 479 0; ws_pid_add 479 abc; ws_pid_add 479 -5
  ws_cleanup 479 >/dev/null 2>&1; assert_eq "$?" "0" "a junk pids line (0, text, a negative number) is skipped, not killed"
  assert_ok "and nothing else died" alive "$other"; kill $other 2>/dev/null
  finish ) || rc=1

echo "# run: the whole sequence"
( fresh_env; export WS_LOG="$T/run.log"
  out="$(ws_run 479 base 'echo hello-from-winsma' 2>&1)"; rc=$?
  assert_eq "$rc" "0" "lock → isolate → guard → command → guard → scan → cleanup passes"
  for want in "lock: hx-lock taken by #479" "guard: before recorded" "hello-from-winsma" "guard: no change" "credentials: GH_TOKEN written nowhere new" "cleanup: winsma clean" "run: OK"; do
    [[ "$out" == *"$want"* ]]; assert_eq "$?" "0" "log has: $want"
  done
  assert_no "folder gone" test -e "$WS_C/hx-479"; assert_no "lock gone" test -e "$WS_C/hx-lock"
  [[ "$(cat "$WS_LOG")" != *"$TOK"* ]]; assert_eq "$?" "0" "the log holds no token"
  finish ) || rc=1
( fresh_env
  out="$(ws_run 479 base 'echo tamper >>"$HX_REAL_HOME/.gitconfig"' 2>&1)"; rc=$?
  assert_eq "$rc" "1" "a command that changes the machine fails the run…"; [[ "$out" == *"GUARD FAILED"* && "$out" == *"run: FAILED at guard after"* ]]; assert_eq "$?" "0" "…at the guard"
  assert_no "…and cleanup still ran" test -e "$WS_C/hx-479"; assert_no "…and released the lock" test -e "$WS_C/hx-lock"
  finish ) || rc=1
( fresh_env
  out="$(ws_run 479 base 'exit 3' 2>&1)"; rc=$?
  assert_eq "$rc" "1" "a failing command fails the run"; [[ "$out" == *"FAILED at command"* ]]; assert_eq "$?" "0" "and says so"
  assert_no "cleanup still ran" test -e "$WS_C/hx-479"
  finish ) || rc=1
( fresh_env; seed_lock 111 lane-b 999999 10; export WS_LOCK_TIMEOUT=1
  ws_run 479 base 'echo never' >/dev/null 2>&1; assert_eq "$?" "1" "a run that cannot get the lock does not run"
  assert_no "and creates no folder" test -e "$WS_C/hx-479"
  finish ) || rc=1
exit $rc
