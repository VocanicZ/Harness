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
    WS_POLL=0.2 WS_LOCK_TIMEOUT=0 WS_STALE_SEC=1800 TEMP="$T/temp" TMP="$T/temp" GH_CONFIG_DIR="$T/home/ghcfg"
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
